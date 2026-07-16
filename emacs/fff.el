;;; fff.el --- Fast file finding for Emacs via fff.nvim -*- lexical-binding: t -*-

;; Package-Requires: ((emacs "28.1") (consult "1.0"))
;; Keywords: files, search
;; SPDX-License-Identifier: MIT

;;; Commentary:
;;
;; Minimal Emacs integration for the upstream fff.nvim C API.
;;
;; This package intentionally only does three things:
;;
;; - `fff-find-file`
;; - `fff-grep`
;; - `fff-grep-fuzzy`
;;
;; It uses Consult for the UI and emacs-ffi for the C bindings.

;;; Code:

(require 'cl-lib)
(require 'consult)
(require 'ffi)
(require 'project)
(require 'subr-x)

;;; Library loading

(defconst fff--library-extension
  (if (eq system-type 'darwin) ".dylib" ".so"))

(defconst fff--library-path
  (let ((dir (file-name-directory (or load-file-name buffer-file-name))))
    (expand-file-name (concat "libfff_c" fff--library-extension) dir)))

(define-ffi-library fff--library
  (if (file-exists-p fff--library-path)
      fff--library-path
    "libfff_c"))

;;; FFI declarations

(define-ffi-function fff--ffi-create-instance
  "fff_create_instance" :pointer
  [:pointer :pointer :pointer :bool :bool :bool]
  fff--library)

(define-ffi-function fff--ffi-destroy
  "fff_destroy" :void [:pointer] fff--library)

(define-ffi-function fff--ffi-search
  "fff_search" :pointer
  [:pointer :pointer :pointer :uint32 :uint32 :uint32 :int32 :uint32]
  fff--library)

(define-ffi-function fff--ffi-live-grep
  "fff_live_grep" :pointer
  [:pointer :pointer :uint8 :uint64 :uint32 :bool :uint32 :uint32 :uint64 :uint32 :uint32 :bool]
  fff--library)

(define-ffi-function fff--ffi-is-scanning
  "fff_is_scanning" :bool [:pointer] fff--library)

(define-ffi-function fff--ffi-track-query
  "fff_track_query" :pointer [:pointer :pointer :pointer] fff--library)

(define-ffi-function fff--ffi-free-result
  "fff_free_result" :void [:pointer] fff--library)

(define-ffi-function fff--ffi-free-search-result
  "fff_free_search_result" :void [:pointer] fff--library)

(define-ffi-function fff--ffi-free-grep-result
  "fff_free_grep_result" :void [:pointer] fff--library)

(define-ffi-function fff--ffi-search-result-get-item
  "fff_search_result_get_item" :pointer [:pointer :uint32] fff--library)

(define-ffi-function fff--ffi-grep-result-get-match
  "fff_grep_result_get_match" :pointer [:pointer :uint32] fff--library)

(define-ffi-function fff--ffi-result-get-success
  "fff_result_get_success" :bool [:pointer] fff--library)

(define-ffi-function fff--ffi-result-get-error
  "fff_result_get_error" :pointer [:pointer] fff--library)

(define-ffi-function fff--ffi-result-get-handle
  "fff_result_get_handle" :pointer [:pointer] fff--library)

(define-ffi-function fff--ffi-search-result-get-count
  "fff_search_result_get_count" :uint32 [:pointer] fff--library)

(define-ffi-function fff--ffi-grep-result-get-count
  "fff_grep_result_get_count" :uint32 [:pointer] fff--library)

(define-ffi-function fff--ffi-file-item-get-relative-path
  "fff_file_item_get_relative_path" :pointer [:pointer] fff--library)

(define-ffi-function fff--ffi-grep-match-get-relative-path
  "fff_grep_match_get_relative_path" :pointer [:pointer] fff--library)

(define-ffi-function fff--ffi-grep-match-get-line-content
  "fff_grep_match_get_line_content" :pointer [:pointer] fff--library)

(define-ffi-function fff--ffi-grep-match-get-line-number
  "fff_grep_match_get_line_number" :uint64 [:pointer] fff--library)

(define-ffi-function fff--ffi-grep-match-get-col
  "fff_grep_match_get_col" :uint32 [:pointer] fff--library)

;;; Result helpers

(defun fff--result-ok-p (result-ptr)
  (fff--ffi-result-get-success result-ptr))

(defun fff--result-error (result-ptr)
  (let ((err-ptr (fff--ffi-result-get-error result-ptr)))
    (unless (ffi-pointer-null-p err-ptr)
      (ffi-get-c-string err-ptr))))

(defun fff--result-handle (result-ptr)
  (fff--ffi-result-get-handle result-ptr))

(defmacro fff--with-cstring (var string &rest body)
  (declare (indent 2))
  `(let ((,var (ffi-make-c-string ,string)))
     (unwind-protect
         (progn ,@body)
       (ffi-free ,var))))

(defmacro fff--with-result (var call &rest body)
  (declare (indent 2))
  (let ((result-ptr (gensym "fff-result-")))
    `(let ((,result-ptr ,call))
       (unwind-protect
           (if (fff--result-ok-p ,result-ptr)
               (let ((,var (fff--result-handle ,result-ptr)))
                 ,@body)
             (error "fff: %s" (fff--result-error ,result-ptr)))
         (fff--ffi-free-result ,result-ptr)))))

;;; Result readers

(defvar fff--base-path nil)

(defun fff--absolute-path (relative-path)
  (when relative-path
    (expand-file-name relative-path fff--base-path)))

(defun fff--search-result-count (search-result-ptr)
  (fff--ffi-search-result-get-count search-result-ptr))

(defun fff--grep-result-count (grep-result-ptr)
  (fff--ffi-grep-result-get-count grep-result-ptr))

(defun fff--file-item-relative-path (item-ptr)
  (let ((path-ptr (fff--ffi-file-item-get-relative-path item-ptr)))
    (unless (ffi-pointer-null-p path-ptr)
      (ffi-get-c-string path-ptr))))

(defun fff--file-item-path (item-ptr)
  (fff--absolute-path (fff--file-item-relative-path item-ptr)))

(defun fff--grep-match-relative-path (match-ptr)
  (let ((path-ptr (fff--ffi-grep-match-get-relative-path match-ptr)))
    (unless (ffi-pointer-null-p path-ptr)
      (ffi-get-c-string path-ptr))))

(defun fff--grep-match-path (match-ptr)
  (fff--absolute-path (fff--grep-match-relative-path match-ptr)))

(defun fff--grep-match-line-content (match-ptr)
  (let ((content-ptr (fff--ffi-grep-match-get-line-content match-ptr)))
    (unless (ffi-pointer-null-p content-ptr)
      (ffi-get-c-string content-ptr))))

(defun fff--grep-match-line (match-ptr)
  (fff--ffi-grep-match-get-line-number match-ptr))

(defun fff--grep-match-col (match-ptr)
  (fff--ffi-grep-match-get-col match-ptr))

;;; Customization

(defgroup fff nil
  "Fast file finding via fff.nvim."
  :group 'tools
  :prefix "fff-")

(defcustom fff-max-results 100
  "Maximum number of results returned for a query."
  :type 'integer
  :group 'fff)

(defcustom fff-max-threads 0
  "Number of worker threads for file search.
0 means auto-detect."
  :type 'integer
  :group 'fff)

(defcustom fff-smart-case t
  "Use smart-case for grep queries."
  :type 'boolean
  :group 'fff)

(defcustom fff-frecency-db-path
  (expand-file-name "fff_nvim" (or (getenv "XDG_CACHE_HOME") "~/.cache"))
  "Path to the frecency database."
  :type 'string
  :group 'fff)

(defcustom fff-history-db-path
  (expand-file-name "fff_queries" (or (getenv "XDG_DATA_HOME") "~/.local/share"))
  "Path to the query history database."
  :type 'string
  :group 'fff)

;;; State

(defvar fff--instance nil)
(defvar fff--last-query "")

(defun fff--project-root ()
  (expand-file-name
   (or (when-let ((project (project-current)))
         (project-root project))
       (user-error "fff: not in a project"))))

(defun fff--destroy-instance ()
  (when fff--instance
    (fff--ffi-destroy fff--instance)
    (setq fff--instance nil
          fff--base-path nil)))

(defun fff--ensure-instance ()
  (let ((base-path (fff--project-root)))
    (unless (equal base-path fff--base-path)
      (fff--destroy-instance))
    (unless fff--instance
      (fff--with-cstring base-path-ptr base-path
        (fff--with-cstring frecency-ptr (expand-file-name fff-frecency-db-path)
          (fff--with-cstring history-ptr (expand-file-name fff-history-db-path)
            (fff--with-result handle
                (fff--ffi-create-instance
                 base-path-ptr frecency-ptr history-ptr nil nil nil)
              (setq fff--instance handle
                    fff--base-path base-path))))))))

(defun fff--wait-for-initial-scan (timeout-ms)
  (let ((deadline (+ (float-time) (/ timeout-ms 1000.0))))
    (while (and (fff--ffi-is-scanning fff--instance)
                (< (float-time) deadline))
      (sleep-for 0.05)))
  (not (fff--ffi-is-scanning fff--instance)))

(defun fff--search-raw (query)
  (fff--with-cstring query-ptr query
    (fff--with-result search-result-ptr
        (fff--ffi-search fff--instance query-ptr (ffi-null-pointer)
                         fff-max-threads 0 fff-max-results 0 0)
      (let ((count (fff--search-result-count search-result-ptr))
            results)
        (dotimes (index count)
          (let ((item-ptr (fff--ffi-search-result-get-item search-result-ptr index)))
            (unless (ffi-pointer-null-p item-ptr)
              (push (list :path (fff--file-item-path item-ptr)
                          :relative-path (fff--file-item-relative-path item-ptr))
                    results))))
        (fff--ffi-free-search-result search-result-ptr)
        (nreverse results)))))

(defun fff--grep-mode-code (mode)
  (if (eq mode 'fuzzy) 2 0))

(defun fff--grep-raw (query mode)
  (fff--with-cstring query-ptr query
    (fff--with-result grep-result-ptr
        (fff--ffi-live-grep fff--instance query-ptr
                            (fff--grep-mode-code mode)
                            0 0
                            fff-smart-case
                            0
                            fff-max-results
                            0 0 0
                            nil)
      (let ((count (fff--grep-result-count grep-result-ptr))
            results)
        (dotimes (index count)
          (let ((match-ptr (fff--ffi-grep-result-get-match grep-result-ptr index)))
            (unless (ffi-pointer-null-p match-ptr)
              (push (list :path (fff--grep-match-path match-ptr)
                          :relative-path (fff--grep-match-relative-path match-ptr)
                          :line (fff--grep-match-line match-ptr)
                          :col (fff--grep-match-col match-ptr)
                          :content (fff--grep-match-line-content match-ptr))
                    results))))
        (fff--ffi-free-grep-result grep-result-ptr)
        (nreverse results)))))

(defun fff--track-selection (path)
  (when (and path
             fff--instance
             (not (string-empty-p fff--last-query)))
    (fff--with-cstring query-ptr fff--last-query
      (fff--with-cstring path-ptr path
        (fff--ffi-free-result
         (fff--ffi-track-query fff--instance query-ptr path-ptr))))))

(defun fff--open-result (plist)
  (let ((path (plist-get plist :path))
        (line (plist-get plist :line))
        (col (plist-get plist :col)))
    (fff--track-selection path)
    (find-file path)
    (when line
      (goto-char (point-min))
      (forward-line (max 0 (1- line))))
    (when col
      (move-to-column (max 0 col)))))

(defun fff--file-candidates (query)
  (setq fff--last-query query)
  (mapcar (lambda (item)
            (cons (or (plist-get item :relative-path)
                      (plist-get item :path))
                  item))
          (fff--search-raw query)))

(defun fff--grep-candidates (query mode)
  (setq fff--last-query query)
  (mapcar (lambda (item)
            (cons
             (format "%s:%d:%d  %s"
                     (or (plist-get item :relative-path)
                         (plist-get item :path))
                     (or (plist-get item :line) 0)
                     (or (plist-get item :col) 0)
                     (or (plist-get item :content) ""))
             item))
          (fff--grep-raw query mode)))

(defun fff--pick-file ()
  (let ((lookup (make-hash-table :test 'equal)))
    (when-let ((choice
                (consult--read
                 (consult--async-dynamic
                  (lambda (input)
                    (mapcar
                     (lambda (item)
                       (let ((display (car item))
                             (value (cdr item)))
                         (puthash display value lookup)
                         display))
                     (fff--file-candidates input))))
                 :prompt "fff › "
                 :sort nil
                 :category 'file
                 :lookup (lambda (candidate _cands _input _narrow)
                           (gethash candidate lookup)))))
      (fff--open-result choice))))

(defun fff--pick-grep (mode)
  (let ((lookup (make-hash-table :test 'equal)))
    (when-let ((choice
                (consult--read
                 (consult--async-dynamic
                  (lambda (input)
                    (mapcar
                     (lambda (item)
                       (let ((display (car item))
                             (value (cdr item)))
                         (puthash display value lookup)
                         display))
                     (fff--grep-candidates input mode))))
                 :prompt (if (eq mode 'fuzzy) "fff grep fuzzy › " "fff grep › ")
                 :sort nil
                 :lookup (lambda (candidate _cands _input _narrow)
                           (gethash candidate lookup)))))
      (fff--open-result choice))))

;;;###autoload
(defun fff-find-file ()
  "Open the file finder for the current project."
  (interactive)
  (fff--ensure-instance)
  (if (fff--wait-for-initial-scan 10000)
      (fff--pick-file)
    (user-error "fff: initial scan timed out")))

;;;###autoload
(defun fff-grep ()
  "Open plain-text grep for the current project."
  (interactive)
  (fff--ensure-instance)
  (fff--pick-grep 'plain))

;;;###autoload
(defun fff-grep-fuzzy ()
  "Open fuzzy grep for the current project."
  (interactive)
  (fff--ensure-instance)
  (fff--pick-grep 'fuzzy))

(add-hook 'kill-emacs-hook #'fff--destroy-instance)

(provide 'fff)
;;; fff.el ends here
