;;;; src/conditions.lisp
;;;;
;;;; The single error condition signalled by PARSE.  Kept intentionally small
;;;; (position + context + the original text) so callers can build their own
;;;; diagnostics (line/column, source snippets, ...) instead of us guessing
;;;; at a message format.

(in-package #:json-kit)

(define-condition json-parse-error (error)
  ((position :initarg :position :reader json-parse-error-position)
   (context :initarg :context :reader json-parse-error-context)
   (text :initarg :text :reader json-parse-error-text))
  (:report (lambda (c s)
             (format s "~A parse error at position ~D"
                     (json-parse-error-context c)
                     (json-parse-error-position c)))))
