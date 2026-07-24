;;;; src/conversion.lisp
;;;;
;;;; Explicit bridges between ALISTs and the HASH-TABLE / ordered JSON-OBJECT
;;;; representations.  They exist precisely so a caller who *does* mean "this
;;;; alist is a JSON object" says so in one place, instead of STRINGIFY trying
;;;; to infer object intent from the shape of an arbitrary cons list.
(in-package #:json-kit)

(defun validate-conversion-max-elements (max-elements)
  (unless (typep max-elements '(integer 0 *))
    (serialization-error "MAX-ELEMENTS must be a nonnegative integer, got ~A"
                         (safe-diagnostic-snippet max-elements))))

(defun validate-alist (alist max-elements)
  "Validate ALIST as a proper list of (string . value) conses within
MAX-ELEMENTS in one bounded, cycle-safe traversal, and return its element count."
  (validate-conversion-max-elements max-elements)
  (do-proper-list (pair alist :count index
                   :improper (serialization-error "ALIST->JSON-OBJECT requires a proper list")
                   :circular (serialization-error "Circular ALIST cannot be converted"))
    (unless (consp pair)
      (serialization-error "ALIST->JSON-OBJECT requires (key . value) conses, got ~A"
                           (safe-diagnostic-snippet pair)))
    (unless (stringp (car pair))
      (serialization-error "ALIST->JSON-OBJECT requires string keys, got ~A"
                           (safe-diagnostic-snippet (car pair))))
    (when (>= index max-elements)
      (serialization-error "ALIST conversion exceeds ~A elements"
                           (safe-diagnostic-snippet max-elements)))))

(defun json-object-members (object)
  "A fresh alist containing the ordered members of OBJECT."
  (copy-alist (%json-object-members object)))

(defun make-json-object (members &key (max-elements 1000000))
  "Create an ordered JSON object from MEMBERS, preserving duplicate keys."
  (check-type members list)
  (validate-alist members max-elements)
  (%make-json-object (copy-alist members)))

(defun alist->json-object (alist &key (max-elements 1000000) (duplicate-key-policy :error))
  "Explicitly convert ALIST into a JSON object representation: an ordered
JSON-OBJECT under :PRESERVE, otherwise a HASH-TABLE resolving duplicate keys by
:ERROR, :FIRST, or :LAST."
  (check-type alist list)
  (unless (member duplicate-key-policy '(:error :first :last :preserve))
    (serialization-error "Unknown duplicate key policy ~A"
                         (safe-diagnostic-snippet duplicate-key-policy)))
  (if (eq duplicate-key-policy :preserve)
      (make-json-object alist :max-elements max-elements)
      (let* ((count (validate-alist alist max-elements))
             (table (make-hash-table :test #'equal :size count)))
        (dolist (pair alist table)
          (multiple-value-bind (old-value present-p) (gethash (car pair) table)
            (declare (ignore old-value))
            (cond
              ((not present-p) (setf (gethash (car pair) table) (cdr pair)))
              ((eq duplicate-key-policy :last) (setf (gethash (car pair) table) (cdr pair)))
              ((eq duplicate-key-policy :error)
               (serialization-error "Duplicate JSON object key ~A"
                                    (safe-diagnostic-snippet (car pair))))))))))

(defun json-object->alist (object &key (max-elements 1000000))
  "Convert a HASH-TABLE, ordered JSON-OBJECT, or ALIST into a fresh bounded
alist with validated string keys."
  (validate-conversion-max-elements max-elements)
  (etypecase object
    (hash-table
     (let ((count (hash-table-count object)))
       (when (> count max-elements)
         (serialization-error "JSON object conversion exceeds ~A elements"
                              (safe-diagnostic-snippet max-elements)))
       (maphash
        (lambda (key value)
          (declare (ignore value))
          (unless (stringp key)
            (serialization-error "JSON-OBJECT->ALIST requires string keys, got ~A"
                                 (safe-diagnostic-snippet key))))
        object)
       (hash-table-pairs object)))
    (json-object
     (let ((members (%json-object-members object)))
       (validate-alist members max-elements)
       (copy-alist members)))
    (list
     (validate-alist object max-elements)
     (copy-alist object))))
