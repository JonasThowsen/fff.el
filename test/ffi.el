;;; ffi.el --- Test double for fff.el unit tests -*- lexical-binding: t -*-

(defmacro define-ffi-library (symbol _name)
  `(defun ,symbol () nil))

(defmacro define-ffi-function (name _c-name _return-type _arg-types _library)
  `(defun ,name (&rest _args)
     (error "Unexpected FFI call to %s" ',name)))

(defun ffi-get-c-string (value)
  value)

(defun ffi-pointer-null-p (value)
  (null value))

(provide 'ffi)
