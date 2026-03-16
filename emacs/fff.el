;;; fff.el --- Fast file finder for Emacs -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "27.1"))

(require 'cl-lib)
(require 'json)
(require 'project)
(require 'subr-x)

(defgroup fff nil
  "Fast file and grep finder backed by fff-core."
  :group 'tools)

(defcustom fff-helper-command nil
  "Command used to start the `fff-emacs' helper process.

When nil, `fff.el' tries `fff-emacs' from `exec-path', then repo-local build
artifacts, then `cargo run' from this checkout. You can set this to either an
executable path string or a full command list."
  :type '(choice (const :tag "Auto-detect" nil)
                 (string :tag "Executable")
                 (repeat :tag "Command list" string))
  :group 'fff)

(defcustom fff-storage-directory (locate-user-emacs-file "fff/")
  "Directory used for fff frecency and query history databases."
  :type 'directory
  :group 'fff)

(defcustom fff-search-page-size 150
  "Maximum number of file matches requested for a single query."
  :type 'integer
  :group 'fff)

(defcustom fff-grep-page-size 150
  "Maximum number of grep matches requested per helper roundtrip."
  :type 'integer
  :group 'fff)

(defcustom fff-grep-max-results 400
  "Maximum number of grep matches collected before rendering the picker."
  :type 'integer
  :group 'fff)

(defcustom fff-grep-mode-cycle '("plain" "fuzzy" "regex")
  "Ordered grep modes used by `fff-live-grep' and Shift-Tab cycling.

The first entry is the default mode for `fff-live-grep'."
  :type '(repeat (choice (const "plain")
                         (const "fuzzy")
                         (const "regex")))
  :group 'fff)

(defcustom fff-request-timeout 10
  "Seconds to wait for helper responses before failing."
  :type 'number
  :group 'fff)

(defcustom fff-query-debounce-delay 0.04
  "Seconds to wait after typing before sending a new search request."
  :type 'number
  :group 'fff)

(defcustom fff-preview-delay 0.03
  "Seconds to wait before refreshing the preview after selection changes."
  :type 'number
  :group 'fff)

(defcustom fff-picker-window-height 14
  "Height of the bottom picker window in lines."
  :type 'integer
  :group 'fff)

(defface fff-file-name-face
  '((t :inherit default :weight semibold))
  "Face used for file names in the picker."
  :group 'fff)

(defface fff-path-face
  '((t :inherit shadow))
  "Face used for parent directories in the picker."
  :group 'fff)

(defface fff-status-face
  '((t :inherit font-lock-keyword-face))
  "Face used for non-clean git statuses in the picker."
  :group 'fff)

(defface fff-match-line-face
  '((t :inherit default))
  "Face used for grep match content."
  :group 'fff)

(cl-defstruct (fff--session (:constructor fff--make-session))
  root
  process
  buffer
  partial
  responses
  callbacks
  ready
  next-id)

(cl-defstruct (fff--picker (:constructor fff--make-picker))
  kind
  mode
  session
  root
  query
  items
  selected-index
  location
  status
  last-error
  truncated
  origin-window
  origin-buffer
  picker-window
  preview-buffer
  preview-path
  refresh-timer
  debounce-timer
  preview-timer
  request-token
  loading
  preview-frozen)

(defvar fff--sessions (make-hash-table :test #'equal))
(defvar fff--find-history nil)
(defvar fff--grep-history nil)
(defvar-local fff--picker nil)

(declare-function fff-picker-refresh "fff")
(declare-function evil-emacs-state "evil")

(defun fff--repo-root ()
  (let* ((library-file (or load-file-name (buffer-file-name)))
         (library-dir (and library-file (file-name-directory library-file))))
    (when library-dir
      (expand-file-name ".." library-dir))))

(defun fff--helper-binary ()
  (let ((repo-root (fff--repo-root)))
    (cl-loop for candidate in (list (and repo-root (expand-file-name "target/release/fff-emacs" repo-root))
                                    (and repo-root (expand-file-name "target/debug/fff-emacs" repo-root)))
             when (and candidate (file-executable-p candidate))
             return candidate)))

(defun fff--helper-base-command ()
  (cond
   ((stringp fff-helper-command)
    (list fff-helper-command))
   ((consp fff-helper-command)
    fff-helper-command)
   ((executable-find "fff-emacs")
    (list (executable-find "fff-emacs")))
   ((fff--helper-binary)
    (list (fff--helper-binary)))
   ((and (fff--repo-root) (executable-find "cargo"))
    (list "cargo"
          "run"
          "--quiet"
          "--manifest-path"
          (expand-file-name "Cargo.toml" (fff--repo-root))
          "--bin"
          "fff-emacs"
          "--"))
   (t
    (user-error
     "Could not find `fff-emacs'; build it or set `fff-helper-command'"))))

(defun fff--project-root ()
  (let* ((dir (expand-file-name default-directory))
         (project (project-current nil dir)))
    (expand-file-name (if project (project-root project) dir))))

(defun fff--session-key (root)
  (file-truename root))

(defun fff--session-hash (root)
  (secure-hash 'sha1 (fff--session-key root)))

(defun fff--db-path (kind root)
  (let ((dir (expand-file-name kind fff-storage-directory)))
    (make-directory dir t)
    (expand-file-name (concat (fff--session-hash root) ".mdb") dir)))

(defun fff--session-live-p (session)
  (and session (process-live-p (fff--session-process session))))

(defun fff--stderr-tail (session)
  (when-let ((buffer (fff--session-buffer session)))
    (with-current-buffer buffer
      (string-trim (buffer-substring-no-properties (point-min) (point-max))))))

(defun fff--json-parse (string)
  (json-parse-string string
                     :object-type 'hash-table
                     :array-type 'list
                     :null-object nil
                     :false-object nil))

(defun fff--json-serialize (object)
  (let ((json-null nil)
        (json-false json-false)
        (json-object-type 'alist)
        (json-array-type 'list))
    (json-encode object)))

(defun fff--helper-command (root)
  (append (fff--helper-base-command)
          (list "--base-path" root
                "--frecency-db-path" (fff--db-path "frecency" root)
                "--history-db-path" (fff--db-path "history" root))))

(defun fff--process-filter (process chunk)
  (let* ((session (process-get process 'fff-session))
         (text (concat (or (fff--session-partial session) "") chunk))
         (finished (string-suffix-p "\n" text))
         (parts (split-string text "\n"))
         (lines (if finished parts (butlast parts)))
         (rest (if finished "" (car (last parts)))))
    (setf (fff--session-partial session) rest)
    (dolist (line lines)
      (unless (string-empty-p line)
        (condition-case nil
            (let ((payload (fff--json-parse line)))
              (if-let ((event (gethash "event" payload)))
                  (when (equal event "ready")
                    (setf (fff--session-ready session) t))
                (let* ((id (gethash "id" payload))
                       (callback (and id (gethash id (fff--session-callbacks session)))))
                  (if callback
                      (progn
                        (remhash id (fff--session-callbacks session))
                        (run-at-time 0 nil callback payload))
                    (puthash id payload (fff--session-responses session))))))
          (error nil))))))

(defun fff--process-sentinel (process _event)
  (unless (process-live-p process)
    (when-let ((session (process-get process 'fff-session)))
      (remhash (fff--session-root session) fff--sessions))))

(defun fff--wait-for (session predicate timeout description)
  (let ((deadline (+ (float-time) timeout)))
    (while (and (fff--session-live-p session)
                (not (funcall predicate))
                (< (float-time) deadline))
      (accept-process-output (fff--session-process session) 0.05))
    (unless (funcall predicate)
      (error "fff helper %s timed out%s"
             description
             (if-let ((stderr (fff--stderr-tail session)))
                 (if (string-empty-p stderr)
                     ""
                   (format ": %s" stderr))
               "")))))

(defun fff--start-session (root)
  (let* ((key (fff--session-key root))
         (buffer (generate-new-buffer (format " *fff:%s*" (file-name-nondirectory (directory-file-name key)))))
         (session (fff--make-session
                    :root key
                    :buffer buffer
                    :responses (make-hash-table :test #'eql)
                    :callbacks (make-hash-table :test #'eql)
                    :next-id 0))
         (process (make-process
                   :name (format "fff:%s" (file-name-nondirectory (directory-file-name key)))
                   :buffer buffer
                   :command (fff--helper-command key)
                   :coding 'utf-8-unix
                   :connection-type 'pipe
                   :noquery t
                   :filter #'fff--process-filter
                   :sentinel #'fff--process-sentinel)))
    (setf (fff--session-process session) process)
    (process-put process 'fff-session session)
    (puthash key session fff--sessions)
    (fff--wait-for session (lambda () (fff--session-ready session)) fff-request-timeout "startup")
    session))

(defun fff--ensure-session (&optional root)
  (let* ((key (fff--session-key (or root (fff--project-root))))
         (session (gethash key fff--sessions)))
    (if (fff--session-live-p session)
        session
      (fff--start-session key))))

(defun fff--request (session method params)
  (let* ((id (cl-incf (fff--session-next-id session)))
         (payload (fff--json-serialize
                   `(("id" . ,id)
                     ("method" . ,method)
                     ("params" . ,params)))))
    (process-send-string (fff--session-process session) (concat payload "\n"))
    (fff--wait-for
     session
     (lambda () (gethash id (fff--session-responses session)))
     fff-request-timeout
     (format "while waiting for %s" method))
    (let ((response (gethash id (fff--session-responses session))))
      (remhash id (fff--session-responses session))
      (if (gethash "ok" response)
          (gethash "result" response)
        (error "fff %s failed: %s" method (gethash "error" response))))))

(defun fff--request-async (session method params callback)
  (let* ((id (cl-incf (fff--session-next-id session)))
         (payload (fff--json-serialize
                   `(("id" . ,id)
                     ("method" . ,method)
                     ("params" . ,params)))))
    (puthash id callback (fff--session-callbacks session))
    (process-send-string (fff--session-process session) (concat payload "\n"))
    id))

(defun fff--status (&optional root quiet)
  (let* ((session (fff--ensure-session root))
         (status (fff--request session "status" '())))
    (unless quiet
      (message "fff: %s indexed%s"
               (gethash "indexed_files" status)
               (if (gethash "is_scanning" status)
                   (format ", scanning (%s seen)" (gethash "scanned_files_count" status))
                 "")))
    status))

(defun fff-status ()
  "Show indexing status for the current project."
  (interactive)
  (fff--status))

(defun fff-rescan ()
  "Trigger a full rescan for the current project."
  (interactive)
  (let* ((session (fff--ensure-session))
         (_ (fff--request session "rescan" '())))
    (message "fff: rescan queued")))

(defun fff-refresh-git-status ()
  "Refresh git status metadata in the current project index."
  (interactive)
  (let* ((session (fff--ensure-session))
         (result (fff--request session "refresh_git_status" '())))
    (message "fff: refreshed git status for %s files"
             (gethash "updated_files_count" result))))

(defun fff-reset (&optional root)
  "Stop and forget the current project's helper process."
  (interactive)
  (let* ((key (fff--session-key (or root (fff--project-root))))
         (session (gethash key fff--sessions)))
    (when (fff--session-live-p session)
      (ignore-errors (fff--request session "shutdown" '()))
      (delete-process (fff--session-process session)))
    (when-let ((buffer (and session (fff--session-buffer session))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))
    (remhash key fff--sessions)
    (message "fff: reset %s" key)))

(defun fff--cleanup-sessions ()
  (maphash (lambda (_root session)
             (when (fff--session-live-p session)
               (ignore-errors (fff--request session "shutdown" '()))
               (ignore-errors (delete-process (fff--session-process session)))))
           fff--sessions))

(add-hook 'kill-emacs-hook #'fff--cleanup-sessions)

(defun fff--collect-grep-items (session query mode)
  (let ((items '())
        (file-offset 0)
        (done nil)
        (last-response nil))
    (while (and (not done)
                (< (length items) fff-grep-max-results))
      (setq last-response
            (fff--request session
                          "grep"
                          `(("query" . ,query)
                            ("mode" . ,mode)
                            ("page_limit" . ,(min fff-grep-page-size
                                                   (- fff-grep-max-results (length items))))
                            ("file_offset" . ,file-offset))))
      (setq items (nconc items (copy-sequence (gethash "items" last-response))))
      (setq file-offset (or (gethash "next_file_offset" last-response) 0))
      (setq done (zerop file-offset)))
    (list :items items :response last-response :truncated (not done))))

(defun fff--picker-buffer-name (kind mode)
  (pcase kind
    ('files "*fff-find*")
    ('grep (format "*fff-grep:%s*" mode))
    (_ "*fff*")))

(defun fff--ensure-picker-layout (picker buffer)
  (let* ((origin-window (or (fff--picker-origin-window picker) (selected-window)))
         (live-origin (if (window-live-p origin-window) origin-window (selected-window)))
         (picker-window (or (fff--picker-picker-window picker)
                            (split-window live-origin (- fff-picker-window-height) 'below))))
    (setf (fff--picker-origin-window picker) live-origin
          (fff--picker-picker-window picker) picker-window)
    (set-window-buffer picker-window buffer)
    (set-window-dedicated-p picker-window t)
    (select-window picker-window)
    picker-window))

(defun fff--preview-window (picker)
  (let ((window (fff--picker-origin-window picker)))
    (cond
     ((window-live-p window) window)
     ((window-live-p (fff--picker-picker-window picker))
      (or (window-in-direction 'above (fff--picker-picker-window picker))
          (selected-window)))
     (t (selected-window)))))

(defun fff--goto-location (location)
  (when location
    (pcase (gethash "type" location)
      ("line"
       (goto-char (point-min))
       (forward-line (max 0 (1- (gethash "line" location)))))
      ("position"
       (goto-char (point-min))
       (forward-line (max 0 (1- (gethash "line" location))))
       (move-to-column (max 0 (1- (gethash "col" location)))))
      ("range"
       (let ((start (gethash "start" location)))
         (goto-char (point-min))
         (forward-line (max 0 (1- (gethash "line" start))))
         (move-to-column (max 0 (1- (gethash "col" start)))))))))

(defun fff--goto-grep-item (item)
  (goto-char (point-min))
  (forward-line (max 0 (1- (gethash "line_number" item))))
  (move-to-column (max 0 (gethash "col" item))))

(defun fff--preview-insert-file (path)
  (let ((inhibit-read-only t)
        (coding-system-for-read 'utf-8-auto))
    (erase-buffer)
    (condition-case err
        (progn
          (insert-file-contents path nil 0 40000)
          (goto-char (point-min))
          (fundamental-mode)
          (setq-local buffer-read-only t)
          (setq-local truncate-lines t)
          (setq-local cursor-type nil)
          (setq-local mode-line-format nil)
          (setq-local header-line-format
                      (concat " " (abbreviate-file-name path) " ")))
      (error
       (insert (format "Could not preview %s\n\n%s"
                       (abbreviate-file-name path)
                       (error-message-string err)))))))

(defun fff--ensure-preview-buffer (picker path)
  (let ((preview (fff--picker-preview-buffer picker)))
    (if (and (buffer-live-p preview)
             (equal (fff--picker-preview-path picker) path))
        preview
      (when (buffer-live-p preview)
        (kill-buffer preview))
      (let ((new-preview
             (generate-new-buffer
              (generate-new-buffer-name
               (format " *fff-preview:%s*" (file-name-nondirectory path))))))
        (with-current-buffer new-preview
          (setq-local fff--preview-overlay nil)
          (fff--preview-insert-file path))
        (setf (fff--picker-preview-buffer picker) new-preview
              (fff--picker-preview-path picker) path)
        new-preview))))

(defun fff--preview-highlight ()
  (let ((overlay (or (bound-and-true-p fff--preview-overlay)
                     (setq-local fff--preview-overlay (make-overlay (point-min) (point-min))))))
    (move-overlay overlay (line-beginning-position) (min (point-max) (1+ (line-end-position))))
    (overlay-put overlay 'face 'highlight)
    overlay))

(defun fff--preview-item (picker item)
  (when item
    (let* ((path (gethash "path" item))
           (preview (fff--ensure-preview-buffer picker path))
           (window (fff--preview-window picker)))
      (save-selected-window
        (select-window window)
        (switch-to-buffer preview)
        (pcase (fff--picker-kind picker)
          ('files (fff--goto-location (fff--picker-location picker)))
          ('grep (fff--goto-grep-item item)))
        (fff--preview-highlight)
        (recenter)))))

(defun fff--picker-current-item ()
  (when fff--picker
    (nth (or (fff--picker-selected-index fff--picker) 0)
         (fff--picker-items fff--picker))))

(defun fff--format-file-item (item)
  (let* ((path (gethash "relative_path" item))
         (name (file-name-nondirectory path))
         (dir (or (file-name-directory path) ""))
         (status (gethash "git_status" item))
         (line (concat
                (propertize name 'face 'fff-file-name-face)
                (unless (string-empty-p dir)
                  (propertize (concat "  " dir) 'face 'fff-path-face))
                (unless (or (null status) (string= status "clean"))
                  (propertize (format "  [%s]" status) 'face 'fff-status-face)))))
    (or line path)))

(defun fff--format-grep-item (item)
  (concat
   (propertize
    (format "%s:%s:%s"
            (gethash "relative_path" item)
            (gethash "line_number" item)
            (1+ (gethash "col" item)))
    'face 'fff-file-name-face)
   (propertize "  " 'face 'default)
   (propertize (string-trim (gethash "line_content" item)) 'face 'fff-match-line-face)))

(defun fff--format-item (picker item)
  (pcase (fff--picker-kind picker)
    ('files (fff--format-file-item item))
    ('grep (fff--format-grep-item item))
    (_ "")))

(defun fff--picker-empty-line (picker)
  (let ((status (fff--picker-status picker)))
    (if (and status (gethash "is_scanning" status))
        (format "Scanning... %s files seen so far (type to search while indexing)"
                (gethash "scanned_files_count" status))
      "No matches - type to search")))

(defun fff--picker-show-message (message)
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert message "\n")
    (goto-char (point-min))))

(defun fff--picker-query-line (picker)
  (format "Query: %s_"
          (if (string-empty-p (fff--picker-query picker))
              ""
            (fff--picker-query picker))))

(defun fff--default-grep-mode ()
  (let ((mode (fff--normalize-grep-mode (car fff-grep-mode-cycle))))
    (or mode "plain")))

(defun fff--normalize-grep-mode (mode)
  (pcase mode
    ((or "plain" 'plain) "plain")
    ((or "fuzzy" 'fuzzy) "fuzzy")
    ((or "regex" 'regex) "regex")
    (_ nil)))

(defun fff--next-grep-mode (mode)
  (let* ((modes (delq nil (mapcar #'fff--normalize-grep-mode fff-grep-mode-cycle)))
         (modes (or (cl-remove-duplicates modes :test #'equal)
                    '("plain" "fuzzy" "regex")))
         (index (cl-position (fff--normalize-grep-mode mode) modes :test #'equal)))
    (nth (mod (1+ (or index -1)) (length modes)) modes)))

(defun fff--picker-status-text (picker)
  (cond
   ((fff--picker-loading picker) "loading")
   ((fff--picker-truncated picker) "truncated")
   (t "ready")))

(defun fff--picker-header ()
  (if (not fff--picker)
      ""
    (format
     " FFF %s  [%s]  query: %s  matches: %d  RET open  C-s split-below  C-v split-right  C-n/C-p move  C-u/C-d preview  DEL delete  C-w word  C-k clear  C-l refresh  C-g quit "
     (pcase (fff--picker-kind fff--picker)
        ('files "files")
        ('grep (format "grep:%s  S-TAB cycle" (fff--picker-mode fff--picker)))
        (_ "picker"))
     (fff--picker-status-text fff--picker)
     (if (string-empty-p (fff--picker-query fff--picker)) "<empty>" (fff--picker-query fff--picker))
     (length (fff--picker-items fff--picker)))))

(defun fff--picker-placeholder (picker)
  (cond
   ((fff--picker-last-error picker) (fff--picker-last-error picker))
   ((fff--picker-loading picker)
    (if (fff--picker-items picker)
        nil
      "Searching..."))
   (t (fff--picker-empty-line picker))))

(defun fff--picker-render ()
  (let ((inhibit-read-only t)
        (items (fff--picker-items fff--picker))
        (selected-index (or (fff--picker-selected-index fff--picker) 0)))
    (erase-buffer)
    (insert (propertize (fff--picker-query-line fff--picker) 'face 'minibuffer-prompt) "\n\n")
    (if items
        (cl-loop for item in items
                 for index from 0
                 do
                  (let ((start (point)))
                    (insert (fff--format-item fff--picker item) "\n")
                    (add-text-properties start (point)
                                         `(fff-index ,index
                                                     mouse-face highlight
                                                     help-echo "RET opens, movement previews"))))
      (insert (fff--picker-placeholder fff--picker) "\n"))
    (goto-char (point-min))
    (forward-line 2)
    (when items
      (forward-line (min selected-index (1- (length items)))))
    (setq mode-line-format nil)))

(defun fff--picker-sync-selection-from-point ()
  (when fff--picker
    (let ((index (get-text-property (line-beginning-position) 'fff-index)))
      (when index
        (setf (fff--picker-selected-index fff--picker) index)))))

(defun fff--picker-schedule-preview ()
  (when (and fff--picker
             (timerp (fff--picker-preview-timer fff--picker)))
    (cancel-timer (fff--picker-preview-timer fff--picker)))
  (when (and fff--picker
             (not (fff--picker-preview-frozen fff--picker))
             (fff--picker-items fff--picker))
    (setf (fff--picker-preview-timer fff--picker)
          (run-with-timer
           fff-preview-delay
           nil
           (lambda (buffer token)
             (when (buffer-live-p buffer)
               (with-current-buffer buffer
                 (when (and fff--picker
                            (= token (or (fff--picker-request-token fff--picker) 0)))
                   (setf (fff--picker-preview-timer fff--picker) nil)
                   (fff--preview-item fff--picker (fff--picker-current-item))))))
           (current-buffer)
           (or (fff--picker-request-token fff--picker) 0)))))

(defun fff--picker-request-status (buffer picker token)
  (fff--request-async
   (fff--picker-session picker)
   "status"
   '()
   (lambda (response)
     (when (buffer-live-p buffer)
       (with-current-buffer buffer
         (when (and fff--picker
                    (= token (or (fff--picker-request-token fff--picker) 0)))
           (if (gethash "ok" response)
               (setf (fff--picker-status fff--picker) (gethash "result" response))
             (setf (fff--picker-last-error fff--picker)
                   (format "fff status failed: %s" (gethash "error" response))))
           (fff--picker-render)))))))

(defun fff--picker-apply-results (buffer token apply-fn)
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (and fff--picker
                 (= token (or (fff--picker-request-token fff--picker) 0)))
        (funcall apply-fn fff--picker)
        (setf (fff--picker-loading fff--picker) nil)
        (fff--picker-render)
        (if (fff--picker-items fff--picker)
            (progn
              (fff--picker-sync-selection-from-point)
              (unless (fff--picker-preview-frozen fff--picker)
                (fff--picker-schedule-preview)))
          (fff--picker-request-status buffer fff--picker token))))))

(defun fff--picker-request-grep-page (buffer picker token items file-offset truncated)
  (fff--request-async
   (fff--picker-session picker)
   "grep"
   `(("query" . ,(fff--picker-query picker))
     ("mode" . ,(fff--picker-mode picker))
     ("page_limit" . ,(min fff-grep-page-size
                            (max 1 (- fff-grep-max-results (length items)))))
     ("file_offset" . ,file-offset))
   (lambda (response)
     (if (not (gethash "ok" response))
         (fff--picker-apply-results
          buffer token
          (lambda (active-picker)
            (setf (fff--picker-items active-picker) nil
                  (fff--picker-last-error active-picker)
                  (format "fff grep failed: %s" (gethash "error" response)))))
       (let* ((result (gethash "result" response))
              (page-items (or (gethash "items" result) '()))
              (all-items (nconc items (copy-sequence page-items)))
              (next-offset (or (gethash "next_file_offset" result) 0))
              (done (or (zerop next-offset)
                        (>= (length all-items) fff-grep-max-results))))
         (if done
             (fff--picker-apply-results
              buffer token
              (lambda (active-picker)
                (setf (fff--picker-items active-picker) all-items
                      (fff--picker-selected-index active-picker)
                      (if all-items
                          (min (or (fff--picker-selected-index active-picker) 0)
                               (1- (length all-items)))
                        0)
                      (fff--picker-location active-picker) nil
                      (fff--picker-status active-picker) nil
                      (fff--picker-last-error active-picker) nil
                      (fff--picker-truncated active-picker)
                      (or truncated (not (zerop next-offset))))))
           (fff--picker-request-grep-page
            buffer picker token all-items next-offset truncated)))))))

(defun fff--picker-refresh (&optional background)
  (interactive)
  (unless fff--picker
    (user-error "No active fff picker"))
  (let* ((picker fff--picker)
         (buffer (current-buffer))
         (token (1+ (or (fff--picker-request-token picker) 0)))
         (show-loading (and (not background)
                            (null (fff--picker-items picker)))))
    (setf (fff--picker-request-token picker) token
          (fff--picker-loading picker) show-loading
          (fff--picker-last-error picker) nil)
    (when show-loading
      (setf (fff--picker-status picker) nil)
      (fff--picker-render))
    (pcase (fff--picker-kind picker)
      ('files
       (fff--request-async
        (fff--picker-session picker)
        "search"
        `(("query" . ,(fff--picker-query picker))
          ("page_size" . ,fff-search-page-size))
        (lambda (response)
          (if (not (gethash "ok" response))
              (fff--picker-apply-results
               buffer token
               (lambda (active-picker)
                (setf (fff--picker-items active-picker) nil
                      (fff--picker-last-error active-picker)
                      (format "fff search failed: %s" (gethash "error" response)))))
            (let* ((result (gethash "result" response))
                   (items (or (gethash "items" result) '())))
              (fff--picker-apply-results
               buffer token
               (lambda (active-picker)
                 (setf (fff--picker-items active-picker) items
                       (fff--picker-location active-picker) (gethash "location" result)
                       (fff--picker-selected-index active-picker)
                       (if items
                           (min (or (fff--picker-selected-index active-picker) 0)
                                (1- (length items)))
                         0)
                       (fff--picker-status active-picker) nil
                       (fff--picker-last-error active-picker) nil
                       (fff--picker-truncated active-picker) nil))))))))
      ('grep
       (fff--picker-request-grep-page buffer picker token '() 0 nil)))))

(defun fff--picker-request-refresh (&optional immediate background)
  (unless fff--picker
    (user-error "No active fff picker"))
  (when (timerp (fff--picker-debounce-timer fff--picker))
    (cancel-timer (fff--picker-debounce-timer fff--picker)))
  (if immediate
      (fff--picker-refresh background)
    (setf (fff--picker-debounce-timer fff--picker)
          (run-with-timer
           fff-query-debounce-delay
           nil
           (lambda (buffer delayed-background)
             (when (buffer-live-p buffer)
               (with-current-buffer buffer
                 (when fff--picker
                    (setf (fff--picker-debounce-timer fff--picker) nil)
                   (fff--picker-refresh delayed-background)))))
           (current-buffer)
           background))))

(defun fff--picker-post-command ()
  (when (and (derived-mode-p 'fff-picker-mode)
             fff--picker
             (not (memq this-command '(fff-picker-self-insert
                                       fff-picker-backspace
                                       fff-picker-delete-word
                                       fff-picker-clear-query
                                       fff-picker-refresh))))
    (let ((before (fff--picker-selected-index fff--picker)))
      (fff--picker-sync-selection-from-point)
      (unless (equal before (fff--picker-selected-index fff--picker))
        (setf (fff--picker-preview-frozen fff--picker) nil)
        (fff--picker-schedule-preview)))))

(defvar fff-picker-mode-map
  (let ((map (make-sparse-keymap)))
    (cl-loop for c from 32 to 126
             do (define-key map (char-to-string c) #'fff-picker-self-insert))
    (define-key map (kbd "DEL") #'fff-picker-backspace)
    (define-key map (kbd "<backspace>") #'fff-picker-backspace)
    (define-key map (kbd "C-n") #'next-line)
    (define-key map (kbd "C-p") #'previous-line)
    (define-key map (kbd "C-s") #'fff-picker-open-horizontal)
    (define-key map (kbd "C-v") #'fff-picker-open-vertical)
    (define-key map (kbd "C-g") #'fff-picker-quit)
    (define-key map (kbd "<escape>") #'fff-picker-quit)
    (define-key map (kbd "<backtab>") #'fff-picker-cycle-grep-mode)
    (define-key map (kbd "S-<tab>") #'fff-picker-cycle-grep-mode)
    (define-key map [backtab] #'fff-picker-cycle-grep-mode)
    (define-key map [iso-lefttab] #'fff-picker-cycle-grep-mode)
    (define-key map (kbd "C-d") #'fff-picker-preview-half-page-down)
    (define-key map (kbd "C-w") #'fff-picker-delete-word)
    (define-key map (kbd "C-u") #'fff-picker-preview-half-page-up)
    (define-key map (kbd "C-k") #'fff-picker-clear-query)
    (define-key map (kbd "C-l") (lambda () (interactive) (fff--picker-request-refresh t nil)))
    (define-key map (kbd "RET") #'fff-picker-open)
    (define-key map (kbd "<down>") #'next-line)
    (define-key map (kbd "<up>") #'previous-line)
    (define-key map (kbd "M-<") #'beginning-of-buffer)
    (define-key map (kbd "M->") #'end-of-buffer)
    map))

(define-derived-mode fff-picker-mode special-mode "FFF"
  "Interactive picker for fff-backed file and grep search."
  (setq-local truncate-lines t)
  (setq-local cursor-type 'bar)
  (setq-local header-line-format '(:eval (fff--picker-header)))
  (hl-line-mode 1)
  (when (fboundp 'evil-emacs-state)
    (evil-emacs-state))
  (add-hook 'post-command-hook #'fff--picker-post-command nil t))

(defun fff--picker-cleanup ()
  (when (and fff--picker
             (timerp (fff--picker-refresh-timer fff--picker)))
    (cancel-timer (fff--picker-refresh-timer fff--picker))
    (setf (fff--picker-refresh-timer fff--picker) nil))
  (when (and fff--picker
             (timerp (fff--picker-debounce-timer fff--picker)))
    (cancel-timer (fff--picker-debounce-timer fff--picker))
    (setf (fff--picker-debounce-timer fff--picker) nil))
  (when (and fff--picker
             (timerp (fff--picker-preview-timer fff--picker)))
    (cancel-timer (fff--picker-preview-timer fff--picker))
    (setf (fff--picker-preview-timer fff--picker) nil))
  (when (and fff--picker
             (buffer-live-p (fff--picker-preview-buffer fff--picker)))
    (kill-buffer (fff--picker-preview-buffer fff--picker))
    (setf (fff--picker-preview-buffer fff--picker) nil
          (fff--picker-preview-path fff--picker) nil))
  (when (and fff--picker
             (window-live-p (fff--picker-picker-window fff--picker)))
    (set-window-dedicated-p (fff--picker-picker-window fff--picker) nil))
  (when (and fff--picker
             (window-live-p (fff--picker-origin-window fff--picker))
             (buffer-live-p (fff--picker-origin-buffer fff--picker)))
    (set-window-buffer (fff--picker-origin-window fff--picker)
                       (fff--picker-origin-buffer fff--picker))))

(defun fff--picker-auto-refresh-tick (buffer)
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (and fff--picker
                 (fff--picker-status fff--picker)
                 (gethash "is_scanning" (fff--picker-status fff--picker)))
        (ignore-errors (fff--picker-request-refresh t t))))))

(defun fff--picker-start-auto-refresh ()
  (when (and fff--picker
             (not (timerp (fff--picker-refresh-timer fff--picker))))
    (setf (fff--picker-refresh-timer fff--picker)
          (run-with-timer 0.25 0.25 #'fff--picker-auto-refresh-tick (current-buffer)))))

(defun fff-picker-quit ()
  "Quit the active fff picker and close its preview."
  (interactive)
  (let ((picker fff--picker)
        (buffer (current-buffer)))
    (fff--picker-cleanup)
    (when (and picker (window-live-p (fff--picker-picker-window picker)))
      (delete-window (fff--picker-picker-window picker)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (remove-hook 'kill-buffer-hook #'fff--picker-cleanup t))
      (kill-buffer buffer))))

(defun fff-picker-self-insert (n)
  "Append typed characters to the picker query and refresh."
  (interactive "p")
  (unless fff--picker
    (user-error "No active fff picker"))
  (let ((chars (make-string n last-command-event)))
    (setf (fff--picker-query fff--picker)
          (concat (fff--picker-query fff--picker) chars)
          (fff--picker-selected-index fff--picker) 0
          (fff--picker-preview-frozen fff--picker) nil)
    (fff--picker-request-refresh)))

(defun fff-picker-backspace ()
  "Delete the last character from the picker query and refresh."
  (interactive)
  (unless fff--picker
    (user-error "No active fff picker"))
  (when (> (length (fff--picker-query fff--picker)) 0)
    (setf (fff--picker-query fff--picker)
          (substring (fff--picker-query fff--picker) 0 -1)
          (fff--picker-selected-index fff--picker) 0
          (fff--picker-preview-frozen fff--picker) nil)
    (fff--picker-request-refresh)))

(defun fff-picker-delete-word ()
  "Delete the last word from the picker query and refresh."
  (interactive)
  (unless fff--picker
    (user-error "No active fff picker"))
  (let* ((query (string-trim-right (fff--picker-query fff--picker)))
         (next (if (string-match "[[:space:]]+[^[:space:]]+$" query)
                   (replace-match "" t t query)
                 "")))
    (setf (fff--picker-query fff--picker) (string-trim-right next)
          (fff--picker-selected-index fff--picker) 0
          (fff--picker-preview-frozen fff--picker) nil)
    (fff--picker-request-refresh)))

(defun fff-picker-clear-query ()
  "Clear the picker query and refresh."
  (interactive)
  (unless fff--picker
    (user-error "No active fff picker"))
  (setf (fff--picker-query fff--picker) ""
        (fff--picker-selected-index fff--picker) 0
        (fff--picker-preview-frozen fff--picker) nil)
  (fff--picker-request-refresh))

(defun fff--scroll-preview (direction)
  (unless fff--picker
    (user-error "No active fff picker"))
  (when (timerp (fff--picker-preview-timer fff--picker))
    (cancel-timer (fff--picker-preview-timer fff--picker))
    (setf (fff--picker-preview-timer fff--picker) nil))
  (setf (fff--picker-preview-frozen fff--picker) t)
  (let ((window (fff--preview-window fff--picker)))
    (when (window-live-p window)
      (save-selected-window
        (select-window window)
        (condition-case nil
            (progn
              (funcall direction (/ (max 2 (window-body-height window)) 2))
              (goto-char (window-start window))
              (forward-line (/ (max 2 (window-body-height window)) 2))
              (set-window-point window (point)))
          (error nil))))))

(defun fff-picker-preview-half-page-down ()
  "Scroll the preview window down by half a page."
  (interactive)
  (fff--scroll-preview #'scroll-up-command))

(defun fff-picker-preview-half-page-up ()
  "Scroll the preview window up by half a page."
  (interactive)
  (fff--scroll-preview #'scroll-down-command))

(defun fff-picker-cycle-grep-mode ()
  "Cycle the active grep picker to the next configured grep mode."
  (interactive)
  (unless (and fff--picker (eq (fff--picker-kind fff--picker) 'grep))
    (user-error "Not in an fff grep picker"))
  (setf (fff--picker-mode fff--picker) (fff--next-grep-mode (fff--picker-mode fff--picker))
        (fff--picker-selected-index fff--picker) 0
        (fff--picker-truncated fff--picker) nil
        (fff--picker-last-error fff--picker) nil
        (fff--picker-preview-frozen fff--picker) nil)
  (fff--picker-request-refresh t nil))


(defun fff--picker-run-opener (picker opener path)
  (let ((window (fff--preview-window picker)))
    (save-selected-window
      (select-window window)
      (funcall (or opener #'find-file) path))))

(defun fff--picker-open-file (picker path location &optional opener)
  (fff--picker-run-opener picker opener path)
  (let ((window (fff--preview-window picker)))
    (save-selected-window
      (select-window window)
      (fff--goto-location location)
      (recenter))))

(defun fff--picker-open-grep (picker item &optional opener)
  (fff--picker-run-opener picker opener (gethash "path" item))
  (let ((window (fff--preview-window picker)))
    (save-selected-window
      (select-window window)
      (fff--goto-grep-item item)
      (recenter))))

(defun fff--picker-open (opener)
  (interactive)
  (unless fff--picker
    (user-error "No active fff picker"))
  (let* ((picker fff--picker)
         (item (fff--picker-current-item))
         (buffer (current-buffer))
         (kind (fff--picker-kind picker))
         (location (fff--picker-location picker))
         (query (fff--picker-query picker))
         (session (fff--picker-session picker)))
    (unless item
      (user-error "No selection"))
    (when (eq kind 'files)
      (ignore-errors
        (fff--request session
                      "track_query"
                      `(("query" . ,query)
                        ("path" . ,(gethash "path" item))))))
    (fff--picker-cleanup)
    (when (window-live-p (fff--picker-picker-window picker))
      (delete-window (fff--picker-picker-window picker)))
    (pcase kind
      ('files
       (fff--picker-open-file
        picker
        (gethash "path" item)
        location
        opener))
      ('grep (fff--picker-open-grep picker item opener)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (remove-hook 'kill-buffer-hook #'fff--picker-cleanup t))
      (kill-buffer buffer))))

(defun fff-picker-open ()
  "Open the selected picker item in the current window."
  (interactive)
  (fff--picker-open #'find-file))

(defun fff--find-file-horizontal (path)
  (select-window (split-window-below))
  (find-file path))

(defun fff--find-file-vertical (path)
  (select-window (split-window-right))
  (find-file path))

(defun fff-picker-open-horizontal ()
  "Open the selected picker item in a horizontal split."
  (interactive)
  (fff--picker-open #'fff--find-file-horizontal))

(defun fff-picker-open-vertical ()
  "Open the selected picker item in a vertical split."
  (interactive)
  (fff--picker-open #'fff--find-file-vertical))

(defun fff--open-picker (kind &optional mode initial-query)
  (let* ((origin-window (selected-window))
         (origin-buffer (window-buffer origin-window))
         (session (fff--ensure-session))
         (buffer (get-buffer-create (fff--picker-buffer-name kind mode)))
         (picker (fff--make-picker
                   :kind kind
                   :mode mode
                   :session session
                   :root (fff--session-root session)
                   :origin-window origin-window
                   :origin-buffer origin-buffer
                   :query (or initial-query "")
                   :items nil
                   :selected-index 0)))
    (with-current-buffer buffer
      (setq-local default-directory (fff--session-root session))
      (fff-picker-mode)
      (setq-local fff--picker picker)
      (add-hook 'kill-buffer-hook #'fff--picker-cleanup nil t)
      (fff--ensure-picker-layout picker buffer)
      (fff--picker-start-auto-refresh)
      (fff--picker-refresh))
    buffer))

(with-eval-after-load 'evil
  (when (fboundp 'evil-set-initial-state)
    (evil-set-initial-state 'fff-picker-mode 'emacs)))

(defun fff-find-files (&optional initial-query)
  "Open the interactive file picker with live preview."
  (interactive)
  (fff--open-picker 'files nil initial-query))

(defun fff-live-grep (&optional initial-query)
  "Open the grep picker with the first configured mode and live preview."
  (interactive)
  (fff--open-picker 'grep (fff--default-grep-mode) initial-query))

(defun fff-live-grep-regexp (&optional initial-query)
  "Open the regex grep picker with live preview."
  (interactive)
  (fff--open-picker 'grep "regex" initial-query))

(defun fff-live-grep-fuzzy (&optional initial-query)
  "Open the fuzzy grep picker with live preview."
  (interactive)
  (fff--open-picker 'grep "fuzzy" initial-query))

(provide 'fff)

;;; fff.el ends here
