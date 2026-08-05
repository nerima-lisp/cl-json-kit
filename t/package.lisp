;;;; t/package.lisp
(defpackage #:cl-json-kit/test
  (:use #:cl #:json-kit)
  ;; DESCRIBE clashes with CL:DESCRIBE, so shadow-import cl-weave's.
  (:shadowing-import-from #:cl-weave #:describe)
  (:import-from #:cl-weave
   ;; Registration and assertions
   #:it #:it-each #:it-property #:it-fuzz #:it-sequential
   #:expect #:signals #:run-all
   ;; Custom matcher definition
   #:defmatcher
   ;; Property generators
   #:gen-integer #:gen-string #:gen-vector #:gen-list
   #:gen-one-of #:gen-recursive #:gen-member #:gen-map #:gen-tuple
   ;; Soft (all-failures-collected) assertions
   #:with-soft-assertions
   ;; Fixture hooks
   #:before-each
   ;; Mocking
   #:make-mock-function #:mock-calls
   ;; Mutation testing
   #:run-mutations #:assert-mutation-score)
  (:export #:run-tests))

(in-package #:cl-json-kit/test)

(defun run-tests ()
  "Run every registered spec, signalling on any failure so ASDF's TEST-OP fails.
Every spec gets a 10-second per-attempt wall-clock budget from cl-weave itself,
so a single hanging test fails with a clear timeout status instead of
depending on an external process-level timeout to notice anything is wrong."
  (unless (run-all :reporter :spec :timeout-ms 10000)
    (error "cl-json-kit test suite failed"))
  (format t "~&cl-json-kit/test: successful completion with 0 failures~%")
  t)
