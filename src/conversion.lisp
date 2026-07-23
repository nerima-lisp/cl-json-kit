;;;; src/conversion.lisp
;;;;
;;;; Explicit bridging helpers between ALISTs and the HASH-TABLE object
;;;; representation.  These exist precisely so that a caller who *does* mean
;;;; "this alist is a JSON object" can say so in one place, instead of
;;;; STRINGIFY trying to infer it from the shape of an arbitrary cons list.

(in-package #:json-kit)

(defun alist->json-object (alist)
  "Explicitly mark ALIST (a list of (KEY . VALUE) conses) as a JSON object
payload.  Returns a fresh HASH-TABLE (test #'EQUAL) populated from ALIST, so
that passing the result to STRINGIFY serializes it as a JSON object via the
normal HASH-TABLE branch of its type dispatch -- STRINGIFY itself never
inspects a plain cons list and guesses that it is an alist."
  (check-type alist list)
  (let ((table (make-hash-table :test #'equal)))
    (dolist (pair alist table)
      (unless (consp pair)
        (error "ALIST->JSON-OBJECT: ~S is not a (key . value) cons" pair))
      (setf (gethash (car pair) table) (cdr pair)))))

(defun json-object->alist (obj)
  "Convert OBJ -- a HASH-TABLE (as produced by PARSE with :OBJECT-TYPE
:HASH-TABLE, or by ALIST->JSON-OBJECT) or an existing ALIST -- into a fresh
ALIST of (KEY . VALUE) conses."
  (etypecase obj
    (hash-table (hash-table-pairs obj))
    (list (copy-alist obj))))
