;;;; src/package.lisp
;;;;
;;;; The single public package.  Everything a caller needs -- the two parsing
;;;; entry points, the two writing entry points, the opaque null/false
;;;; sentinels with their predicates, the structured conditions, and the
;;;; explicit alist<->object bridges -- is exported here and nothing else.
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
