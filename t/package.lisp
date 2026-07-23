;;;; t/package.lisp

(defpackage #:cl-json-kit/test
  (:use #:cl #:json-kit)
  (:shadowing-import-from #:cl-weave #:describe)
  (:import-from #:cl-weave #:expect #:it #:signals #:run-all)
  (:export #:run-tests))

(in-package #:cl-json-kit/test)

(defun run-tests ()
  (unless (run-all :reporter :spec)
    (error "cl-json-kit test suite failed"))
  (format t "~&cl-json-kit/test: successful completion with 0 failures~%")
  t)
