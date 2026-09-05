;;;; src/package.lisp
;;;;
;;;; Public package definition.
(defpackage #:json-kit
  (:use #:cl)
  (:export
   ;; Reading
   #:parse
   #:parse-prefix
   #:read-json
   ;; Writing
   #:write-json
   #:stringify
   ;; Opaque JSON null / false
   #:+json-null+
   #:+json-false+
   #:json-null-p
   #:json-false-p
   ;; Base condition
   #:json-kit-error
   ;; Parse diagnostics
   #:json-parse-error
   #:json-parse-error-position
   #:json-parse-error-line
   #:json-parse-error-column
   #:json-parse-error-path
   #:json-parse-error-expected
   #:json-parse-error-context
   #:json-parse-error-text
   ;; Serialization diagnostics
   #:json-serialization-error
   #:json-serialization-error-message
   #:json-serialization-error-path
   ;; Explicit alist <-> ordered-object bridges
   #:make-json-object
   #:json-object-p
   #:json-object-members
   #:alist->json-object
   #:json-object->alist))
