;;;; src/conversion.lisp
;;;;
;;;; Explicit bridging helpers between ALISTs and the HASH-TABLE object
;;;; representation.  These exist precisely so that a caller who *does* mean
;;;; "this alist is a JSON object" can say so in one place, instead of
;;;; STRINGIFY trying to infer it from the shape of an arbitrary cons list.

(in-package #:json-kit)

(progn
  (defun validate-conversion-max-elements (max-elements)
    (unless (typep max-elements (quote (integer 0 *)))
      (serialization-error "MAX-ELEMENTS must be a nonnegative integer, got ~A" (safe-diagnostic-snippet max-elements))))

  (defun validate-alist (alist max-elements)
    "Validate ALIST in one bounded traversal and return its element count."
    (validate-conversion-max-elements max-elements)
    (let ((cursor alist)
          (tortoise alist)
          (power 1)
          (cycle-length 0)
          (count 0))
      (loop
        (when (null cursor)
          (return count))
        (unless (consp cursor)
          (serialization-error "ALIST->JSON-OBJECT requires a proper list"))
        (let ((pair (car cursor)))
          (unless (consp pair)
            (serialization-error "ALIST->JSON-OBJECT requires (key . value) conses, got ~A" (safe-diagnostic-snippet pair)))
          (unless (stringp (car pair))
            (serialization-error "ALIST->JSON-OBJECT requires string keys, got ~A" (safe-diagnostic-snippet (car pair)))))
        (incf count)
        (when (> count max-elements)
          (serialization-error "ALIST conversion exceeds ~A elements" (safe-diagnostic-snippet max-elements)))
        (setf cursor (cdr cursor))
        (incf cycle-length)
        (when (eq cursor tortoise)
          (serialization-error "Circular ALIST cannot be converted"))
        (when (= cycle-length power)
          (setf tortoise cursor
                power (* 2 power)
                cycle-length 0)))))

  (progn
  (progn
  (defun json-object-members (object)
    "Return a fresh ALIST containing the ordered members of OBJECT."
    (copy-alist (%json-object-members object))))

  (defun make-json-object (members &key (max-elements 1000000))
    "Create an ordered JSON object from MEMBERS, preserving duplicate keys."
    (check-type members list)
    (validate-alist members max-elements)
    (%make-json-object (copy-alist members)))

  (defun alist->json-object
        (alist &key (max-elements 1000000) (duplicate-key-policy :error))
    "Explicitly convert ALIST into a JSON object representation."
    (check-type alist list)
    (unless (member duplicate-key-policy (quote (:error :first :last :preserve)))
      (serialization-error "Unknown duplicate key policy ~A" (safe-diagnostic-snippet duplicate-key-policy)))
    (if (eq duplicate-key-policy :preserve)
        (make-json-object alist :max-elements max-elements)
        (let* ((count (validate-alist alist max-elements))
               (table (make-hash-table :test (function equal) :size count)))
          (dolist (pair alist table)
            (multiple-value-bind (old-value present-p)
                (gethash (car pair) table)
              (declare (ignore old-value))
              (cond
                ((not present-p)
                 (setf (gethash (car pair) table) (cdr pair)))
                ((eq duplicate-key-policy :last)
                 (setf (gethash (car pair) table) (cdr pair)))
                ((eq duplicate-key-policy :error)
                 (serialization-error "Duplicate JSON object key ~A" (safe-diagnostic-snippet (car pair)))))))))))

  (defun json-object->alist (obj &key (max-elements 1000000))
  "Convert a HASH-TABLE, ordered JSON object, or ALIST into a fresh bounded ALIST."
  (validate-conversion-max-elements max-elements)
  (etypecase obj
    (hash-table
     (let ((count (hash-table-count obj)))
       (when (> count max-elements)
         (serialization-error "JSON object conversion exceeds ~A elements"
                              (safe-diagnostic-snippet max-elements)))
       (maphash
         (lambda (key value)
           (declare (ignore value))
           (unless (stringp key)
             (serialization-error
               "JSON-OBJECT->ALIST requires string keys, got ~A"
               (safe-diagnostic-snippet key))))
         obj)
       (hash-table-pairs obj)))
    (json-object
     (let ((members (%json-object-members obj)))
       (validate-alist members max-elements)
       (copy-alist members)))
    (list
     (validate-alist obj max-elements)
     (copy-alist obj)))))
