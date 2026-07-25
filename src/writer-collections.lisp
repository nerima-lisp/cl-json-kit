;;;; src/writer-collections.lisp
;;;;
;;;; Serializing the aggregates and dispatching on Lisp type.  A HASH-TABLE (or
;;;; ordered JSON-OBJECT) becomes a JSON object; any non-string VECTOR or LIST
;;;; becomes a JSON array.  A plain cons list is never re-read as an alist of
;;;; pairs -- WRITE-JSON-VALUE branches purely on type, which is exactly the
;;;; guarantee this library sells.
(in-package #:json-kit)

(defun proper-list-length (value)
  "The element count of proper list VALUE, signalling on an improper or
circular list and enforcing MAX-ELEMENTS as it counts."
  (do-proper-list (element value :count index
                   :improper (serialization-error "cannot serialize an improper list")
                   :circular (serialization-error "cannot serialize a circular list"))
    (ensure-element-count (1+ index))))

(defun write-json-array-sequence (sequence level)
  "Serialize a LIST or VECTOR SEQUENCE as a JSON array."
  (ensure-depth level)
  (let ((count (if (listp sequence)
                   (proper-list-length sequence)
                   (length sequence))))
    (ensure-element-count count)
    (with-active-aggregate (sequence)
      (with-json-brackets (#\[ #\] level count)
        (labels ((write-element (element index)
                   (emit-json-member (index level)
                     (with-json-path (index)
                       (write-json-value element (1+ level))))))
          (if (listp sequence)
              (loop for element in sequence
                    for index from 0
                    do (write-element element index))
              (loop for element across sequence
                    for index from 0
                    do (write-element element index))))))))

;;; ---------------------------------------------------------------------
;;; Objects from hash tables
;;; ---------------------------------------------------------------------
(defun hash-table-pairs (table)
  "A fresh list of (KEY . VALUE) conses from TABLE, in arbitrary order."
  (let ((pairs nil))
    (maphash (lambda (key value) (push (cons key value) pairs)) table)
    pairs))

(defun validate-object-keys (table)
  "Ensure TABLE has string keys, no duplicates, and is within MAX-ELEMENTS."
  (ensure-element-count (hash-table-count table))
  (let ((seen (make-hash-table :test #'equal)))
    (maphash
     (lambda (key value)
       (declare (ignore value))
       (unless (stringp key)
         (serialization-error "JSON object keys must be strings, got ~S" key))
       (when (gethash key seen)
         (serialization-error "Duplicate JSON object key ~S" key))
       (setf (gethash key seen) t))
     table)))

(defun validated-object-pairs (table)
  "Validated TABLE pairs sorted by key, for deterministic :SORT-KEYS output."
  (validate-object-keys table)
  (sort (hash-table-pairs table) #'string< :key #'car))

(defun emit-object-member (key value index level)
  "Emit one \"KEY\":VALUE object member at INDEX within an open WITH-JSON-BRACKETS
body nested at LEVEL.  Shared by WRITE-JSON-OBJECT and WRITE-JSON-ORDERED-OBJECT
so hash-table and ordered-object serialization agree on one member shape."
  (emit-json-member (index level)
    (write-json-string key)
    (emit-string (if *json-pretty* ": " ":"))
    (with-json-path (key)
      (write-json-value value (1+ level)))))

(defun write-json-object (table level)
  "Serialize a HASH-TABLE as a JSON object, sorted when *JSON-SORT-KEYS*."
  (ensure-depth level)
  (let ((count (hash-table-count table))
        (pairs (when *json-sort-keys* (validated-object-pairs table))))
    (unless *json-sort-keys* (validate-object-keys table))
    (with-active-aggregate (table)
      (with-json-brackets (#\{ #\} level count)
        (if *json-sort-keys*
            (loop for (key . value) in pairs
                  for index from 0
                  do (emit-object-member key value index level))
            (let ((index 0))
              (maphash
               (lambda (key value)
                 (emit-object-member key value index level)
                 (incf index))
               table)))))))

;;; ---------------------------------------------------------------------
;;; Objects from ordered JSON-OBJECTs
;;; ---------------------------------------------------------------------
(defun write-json-ordered-object (object level)
  "Serialize an ordered JSON-OBJECT, preserving member order and duplicates."
  (ensure-depth level)
  (let* ((members (%json-object-members object))
         (count (proper-list-length members)))
    (dolist (pair members)
      (unless (consp pair)
        (serialization-error "JSON object members must be (key . value) conses"))
      (unless (stringp (car pair))
        (serialization-error "JSON object keys must be strings, got ~S" (car pair))))
    (with-active-aggregate (object)
      (with-json-brackets (#\{ #\} level count)
        (loop for (key . value) in members
              for index from 0
              do (emit-object-member key value index level))))))

;;; ---------------------------------------------------------------------
;;; Type dispatch
;;; ---------------------------------------------------------------------
(defun write-json-value (value level)
  "Serialize any supported VALUE, branching purely on its Lisp type."
  (cond
    ((eq value *json-null-value*) (emit-string "null"))
    ((eq value *json-false-value*) (emit-string "false"))
    ((stringp value) (write-json-string value))
    ((null value) (write-json-array-sequence value level))
    ((eq value t) (emit-string "true"))
    ((numberp value) (write-json-number value))
    ((json-object-p value) (write-json-ordered-object value level))
    ((hash-table-p value) (write-json-object value level))
    ((and (vectorp value) (not (stringp value)))
     (write-json-array-sequence value level))
    ((consp value) (write-json-array-sequence value level))
    ((keywordp value) (serialization-error "cannot serialize keyword ~S" value))
    (t (serialization-error "cannot serialize value of type ~S" (type-of value)))))
