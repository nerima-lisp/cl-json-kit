;;;; src/writer.lisp
;;;;
;;;; STRINGIFY dispatches purely on the Lisp TYPE of VALUE (see the TYPECASE
;;;; in WRITE-JSON-VALUE below).  In particular a HASH-TABLE always becomes a
;;;; JSON object and a (non-string) VECTOR or LIST always becomes a JSON
;;;; array; a plain cons-list is never inspected to see whether it "looks
;;;; like" an alist of key/value pairs.  Anyone who wants an ALIST written as
;;;; a JSON object must say so explicitly with ALIST->JSON-OBJECT first.
(in-package #:json-kit)

(progn
  (defconstant +default-maximum-serialization-depth+ 512)
  (defconstant +default-maximum-serialization-elements+ 1000000)
  (defconstant +default-maximum-output-length+ 16777216)

  (defvar *json-output-stream*)
  (defvar *json-output-count*)
  (defvar *json-maximum-output-length*)
  (defvar *json-maximum-depth*)
  (defvar *json-maximum-elements*)
  (defvar *json-pretty*)
  (defvar *json-indent*)
  (defvar *json-sort-keys*)
  (defvar *json-null-value*)
  (defvar *json-false-value*)
  (defvar *json-number-encoder*)
  (defvar *json-active-aggregates*)
  (defvar *json-serialization-path* nil)

  (defun serialization-error (control &rest arguments)
    (error 'json-serialization-error
           :message (apply #'format nil control arguments)
           :path (reverse *json-serialization-path*)))

  (defun valid-limit-p (value)
    (or (null value) (and (integerp value) (not (minusp value)))))

  (progn
  (defun validate-writer-options (indent maximum-depth maximum-elements maximum-output-length)
    (unless (and (integerp indent) (not (minusp indent)))
      (serialization-error "INDENT must be a non-negative integer, not ~S" indent))
    (dolist (entry (list (cons "MAX-DEPTH" maximum-depth)
                         (cons "MAX-ELEMENTS" maximum-elements)
                         (cons "MAX-OUTPUT-LENGTH" maximum-output-length)))
      (unless (valid-limit-p (cdr entry))
        (serialization-error "~A must be NIL or a non-negative integer, not ~S"
                             (car entry) (cdr entry)))))

  (defun resolve-number-encoder (designator)
    (cond
      ((null designator) nil)
      ((functionp designator) designator)
      ((and (symbolp designator) (fboundp designator))
       (symbol-function designator))
      (t
       (serialization-error "NUMBER-ENCODER must be a function designator")))))

  (defun reserve-output (length)
    (when (and *json-maximum-output-length*
               (> length (- *json-maximum-output-length* *json-output-count*)))
      (serialization-error "serialized output exceeds the configured maximum length"))
    (incf *json-output-count* length))

  (defun emit-string (string)
    (reserve-output (length string))
    (write-string string *json-output-stream*))

  (defun emit-character (character)
    (reserve-output 1)
    (write-char character *json-output-stream*))

  (defun emit-indent (level)
    (emit-character #\Newline)
    (let ((count (* *json-indent* level)))
      (reserve-output count)
      (dotimes (index count)
        (write-char #\Space *json-output-stream*))))

  (defmacro with-json-path ((component) &body body)
    `(let ((*json-serialization-path* (cons ,component *json-serialization-path*)))
       ,@body))

  (defmacro with-active-aggregate ((value) &body body)
    `(progn
       (when (gethash ,value *json-active-aggregates*)
         (serialization-error "circular aggregate value"))
       (setf (gethash ,value *json-active-aggregates*) t)
       (unwind-protect (progn ,@body)
         (remhash ,value *json-active-aggregates*))))

  (defun ensure-depth (level)
    (when (and *json-maximum-depth* (> level *json-maximum-depth*))
      (serialization-error "serialization nesting exceeds MAX-DEPTH")))

  (defun ensure-element-count (count)
    (when (and *json-maximum-elements* (> count *json-maximum-elements*))
      (serialization-error "aggregate contains more than MAX-ELEMENTS elements")))

  (defun json-number-string-p (string) (and (stringp string) (plusp (length string)) (let ((index 0) (size (length string))) (labels ((current () (and (< index size) (char string index))) (digits () (let ((start index)) (loop while (and (current) (let ((character (current))) (and character (char<= #\0 character #\9)))) do (incf index)) (> index start)))) (when (eql (current) #\-) (incf index)) (cond ((eql (current) #\0) (incf index)) ((and (current) (find (current) "123456789" :test #'char=)) (digits)) (t (return-from json-number-string-p nil))) (when (eql (current) #\.) (incf index) (unless (digits) (return-from json-number-string-p nil))) (when (and (current) (find (current) "eE" :test #'char=)) (incf index) (when (and (current) (find (current) "+-" :test #'char=)) (incf index)) (unless (digits) (return-from json-number-string-p nil))) (= index size)))))

  (defun finite-float-p (value)
    #+sbcl
    (not (or (sb-ext:float-nan-p value) (sb-ext:float-infinity-p value)))
    #-sbcl
    (and (= value value)
         (handler-case (progn (integer-decode-float value) t)
           (error () nil))))

  (defun json-float-string (value)
    (unless (finite-float-p value)
      (serialization-error "JSON numbers cannot represent NaN or infinity"))
    (if (zerop value)
        (if (minusp (float-sign value)) "-0.0" "0.0")
        (let* ((*print-readably* t)
               (*print-pretty* nil)
               (printed (write-to-string value))
               (marker (position-if
                         (lambda (character)
                           (find character "dDfFsSlL" :test #'char=))
                         printed)))
          (if marker
              (concatenate 'string (subseq printed 0 marker) "e"
                           (subseq printed (1+ marker)))
              printed))))

  (defun decimal-digit-lower-bound (integer)
    (if (zerop integer)
        1
        (1+ (floor (* (1- (integer-length (abs integer))) 301029) 1000000))))

  (defun ensure-integer-output-budget (integer)
    (when *json-maximum-output-length*
      (let ((minimum (+ (if (minusp integer) 1 0)
                        (decimal-digit-lower-bound integer))))
        (when (> minimum (- *json-maximum-output-length* *json-output-count*))
          (serialization-error "serialized integer exceeds the configured maximum length")))))

  (defun factor-count (integer factor)
    (loop with count = 0
          while (zerop (mod integer factor))
          do (setf integer (/ integer factor))
             (incf count)
          finally (return (values count integer))))

  (defun ratio-scale-lower-bound (denominator)
    (floor (1- (integer-length denominator)) 3))

  (defun terminating-ratio-string (value)
    (let* ((numerator (numerator value))
           (denominator (denominator value))
           (negative (minusp numerator))
           (absolute-numerator (abs numerator))
           (integer-part (floor absolute-numerator denominator))
           (minimum-output-length
             (+ (if negative 1 0)
                (ratio-scale-lower-bound denominator)
                (if (zerop integer-part)
                    2
                    (1+ (decimal-digit-lower-bound integer-part))))))
      (when (and *json-maximum-output-length*
                 (> minimum-output-length
                    (- *json-maximum-output-length* *json-output-count*)))
        (serialization-error "serialized ratio exceeds the configured maximum length"))
      (multiple-value-bind (twos after-twos) (factor-count denominator 2)
        (multiple-value-bind (fives remainder) (factor-count after-twos 5)
          (unless (= remainder 1)
            (serialization-error "ratio has a non-terminating decimal expansion"))
          (let* ((scale (max twos fives))
                 (scaled (* absolute-numerator
                            (expt 2 (- scale twos))
                            (expt 5 (- scale fives))))
                 (digits (write-to-string scaled :base 10 :radix nil))
                 (sign (if negative "-" "")))
            (if (zerop scale)
                (concatenate 'string sign digits)
                (let ((split (- (length digits) scale)))
                  (if (plusp split)
                      (concatenate 'string sign (subseq digits 0 split) "."
                                   (subseq digits split))
                      (concatenate 'string sign "0."
                                   (make-string (- split) :initial-element #\0)
                                   digits)))))))))

  (defun write-json-number (value)
    (let ((encoded
            (if *json-number-encoder*
                (funcall *json-number-encoder* value)
                (typecase value
                  (integer
                   (ensure-integer-output-budget value)
                   (write-to-string value :base 10 :radix nil))
                  (ratio (terminating-ratio-string value))
                  (float (json-float-string value))
                  (t (serialization-error "unsupported number type ~S"
                                          (type-of value)))))))
      (unless (json-number-string-p encoded)
        (serialization-error "number encoder returned an invalid JSON number"))
      (emit-string encoded)))

  (defun write-json-string (string)
    (emit-character #\")
    (loop for character across string
          for code = (char-code character)
          do (cond
               ((<= #xd800 code #xdfff)
                (serialization-error "JSON strings cannot contain raw surrogate characters"))
               ((char= character #\") (emit-string "\\\""))
               ((char= character #\\) (emit-string "\\\\"))
               ((char= character #\Backspace) (emit-string "\\b"))
               ((char= character #\Page) (emit-string "\\f"))
               ((char= character #\Newline) (emit-string "\\n"))
               ((char= character #\Return) (emit-string "\\r"))
               ((char= character #\Tab) (emit-string "\\t"))
               ((< code #x20) (emit-string (format nil "\\u~4,'0X" code)))
               (t (emit-character character))))
    (emit-character #\"))

  (defun proper-list-length (value)
  (let ((tail value)
        (tortoise value)
        (power 1)
        (cycle-length 0)
        (count 0))
    (loop
      (cond
        ((null tail) (return count))
        ((not (consp tail))
         (serialization-error "cannot serialize an improper list"))
        (t
         (incf count)
         (ensure-element-count count)
         (setf tail (cdr tail))
         (incf cycle-length)
         (when (and tail (eq tail tortoise))
           (serialization-error "cannot serialize a circular list"))
         (when (= power cycle-length)
           (setf tortoise tail
                 power (* 2 power)
                 cycle-length 0)))))))

  (defun write-json-array-sequence (sequence level)
    (ensure-depth level)
    (let ((count (if (listp sequence)
                     (proper-list-length sequence)
                     (length sequence))))
      (ensure-element-count count)
      (with-active-aggregate (sequence)
        (labels ((write-element (element index)
                   (unless (zerop index) (emit-character #\,))
                   (when *json-pretty* (emit-indent (1+ level)))
                   (with-json-path (index)
                     (write-json-value element (1+ level)))))
          (emit-character #\[)
          (if (listp sequence)
              (loop for element in sequence
                    for index from 0
                    do (write-element element index))
              (loop for element across sequence
                    for index from 0
                    do (write-element element index)))
          (when (and *json-pretty* (plusp count)) (emit-indent level))
          (emit-character #\])))))

  (progn
 (defun hash-table-pairs (table)
   (let ((pairs nil))
     (maphash (lambda (key value) (push (cons key value) pairs)) table)
     pairs))

 (defun validate-object-keys (table)
   (ensure-element-count (hash-table-count table))
   (let ((seen (make-hash-table :test (function equal))))
     (maphash
       (lambda (key value)
         (declare (ignore value))
         (unless (stringp key)
           (serialization-error "JSON object keys must be strings" :value key))
         (when (gethash key seen)
           (serialization-error "Duplicate JSON object key" :value key))
         (setf (gethash key seen) t))
       table)))

 (defun validated-object-pairs (table)
   (validate-object-keys table)
   (sort (hash-table-pairs table) (function string<) :key (function car))))

  (progn
  (defun write-json-object (table level)
    (ensure-depth level)
    (let ((count (hash-table-count table))
          (pairs (when *json-sort-keys* (validated-object-pairs table))))
      (unless *json-sort-keys* (validate-object-keys table))
      (with-active-aggregate (table)
        (labels ((write-member (key value index)
                   (unless (zerop index) (emit-character #\,))
                   (when *json-pretty* (emit-indent (1+ level)))
                   (write-json-string key)
                   (emit-string (if *json-pretty* ": " ":"))
                   (with-json-path (key)
                     (write-json-value value (1+ level)))))
          (emit-character #\{)
          (if *json-sort-keys*
              (loop for (key . value) in pairs
                    for index from 0
                    do (write-member key value index))
              (let ((index 0))
                (maphash
                  (lambda (key value)
                    (write-member key value index)
                    (incf index))
                  table)))
          (when (and *json-pretty* (plusp count)) (emit-indent level))
          (emit-character #\})))))

  (defun write-json-ordered-object (object level)
    (ensure-depth level)
    (let* ((members (%json-object-members object))
           (count (proper-list-length members)))
      (dolist (pair members)
        (unless (consp pair)
          (serialization-error "JSON object members must be (key . value) conses"))
        (unless (stringp (car pair))
          (serialization-error "JSON object keys must be strings, got ~S" (car pair))))
      (with-active-aggregate (object)
        (emit-character #\{)
        (loop for (key . value) in members
              for index from 0
              do (unless (zerop index) (emit-character #\,))
                 (when *json-pretty* (emit-indent (1+ level)))
                 (write-json-string key)
                 (emit-string (if *json-pretty* ": " ":"))
                 (with-json-path (key)
                   (write-json-value value (1+ level))))
        (when (and *json-pretty* (plusp count)) (emit-indent level))
        (emit-character #\})))))

  (defun write-json-value (value level)
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

  (progn
  (defun resolve-json-output-stream (designator)
    (let ((stream
            (cond
              ((null designator) *standard-output*)
              ((eq designator t) *terminal-io*)
              ((streamp designator) designator)
              (t
               (error (quote json-serialization-error)
                      :message "STREAM must be an output stream designator")))))
      (unless (open-stream-p stream)
        (error (quote json-serialization-error)
               :message "STREAM must designate an open stream"))
      (unless (output-stream-p stream)
        (error (quote json-serialization-error)
               :message "STREAM must designate an output stream"))
      (multiple-value-bind (character-stream-p certain-p)
          (subtypep (stream-element-type stream) (quote character))
        (unless (and certain-p character-stream-p)
          (error (quote json-serialization-error)
                 :message "STREAM must designate a character output stream")))
      stream))

  (defun write-json
      (value stream
       &key pretty (indent 2) sort-keys
         (null-value +json-null+) (false-value +json-false+) number-encoder
         (max-depth +default-maximum-serialization-depth+)
         (max-elements +default-maximum-serialization-elements+)
         max-output-chars
         (max-output-length +default-maximum-output-length+
                            max-output-length-supplied-p))
    (let ((maximum-output-length
            (cond
  ((not (valid-limit-p max-output-chars))
   (serialization-error "MAX-OUTPUT-CHARS must be NIL or a non-negative integer, not ~S"
                        max-output-chars))
  ((not (valid-limit-p max-output-length))
   (serialization-error "MAX-OUTPUT-LENGTH must be NIL or a non-negative integer, not ~S"
                        max-output-length))
  ((and max-output-chars max-output-length-supplied-p
        (/= max-output-chars max-output-length))
   (serialization-error "MAX-OUTPUT-CHARS and MAX-OUTPUT-LENGTH disagree"))
  (max-output-chars max-output-chars)
  (t max-output-length))))
      (let ((*json-output-stream* (resolve-json-output-stream stream))
            (*json-output-count* 0)
            (*json-maximum-output-length* maximum-output-length)
            (*json-maximum-depth* max-depth)
            (*json-maximum-elements* max-elements)
            (*json-pretty* pretty)
            (*json-indent* indent)
            (*json-sort-keys* sort-keys)
            (*json-null-value* null-value)
            (*json-false-value* false-value)
            (*json-number-encoder* (resolve-number-encoder number-encoder))
            (*json-active-aggregates* (make-hash-table :test (function eq)))
            (*json-serialization-path* nil))
        (validate-writer-options indent max-depth max-elements maximum-output-length)
        (write-json-value value 0)
        value))))

  (defun stringify
      (value
       &rest arguments
       &key pretty indent sort-keys null-value false-value number-encoder
         max-depth max-elements max-output-chars max-output-length
       &allow-other-keys)
    (declare (ignore pretty indent sort-keys null-value false-value number-encoder
                     max-depth max-elements max-output-chars max-output-length))
    (with-output-to-string (stream)
      (apply #'write-json value stream arguments))))
