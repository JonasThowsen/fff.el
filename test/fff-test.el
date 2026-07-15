;;; fff-test.el --- Tests for fff.el -*- lexical-binding: t -*-

(require 'ert)

(let ((root (expand-file-name ".." (file-name-directory (or load-file-name buffer-file-name)))))
  (add-to-list 'load-path (expand-file-name "emacs" root) t))

(require 'fff)

(ert-deftest fff-result-helpers-use-stable-accessors ()
  (let ((result (make-symbol "result"))
        (success t)
        (error "failed")
        (handle (make-symbol "handle")))
    (cl-letf (((symbol-function 'fff--ffi-result-get-success)
               (lambda (pointer) (and (eq pointer result) success)))
              ((symbol-function 'fff--ffi-result-get-error)
               (lambda (pointer) (and (eq pointer result) error)))
              ((symbol-function 'fff--ffi-result-get-handle)
               (lambda (pointer) (and (eq pointer result) handle))))
      (should (fff--result-ok-p result))
      (should (equal (fff--result-error result) error))
      (should (eq (fff--result-handle result) handle)))))

(ert-deftest fff-absolute-path-uses-project-root ()
  (let ((fff--base-path "/tmp/project/"))
    (should (equal (fff--absolute-path "src/main.rs")
                   "/tmp/project/src/main.rs"))))
