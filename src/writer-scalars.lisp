;;;; src/writer-scalars.lisp
;;;;
;;;; Serializing the leaf values: numbers and strings.  Integers print exactly;
;;;; ratios print only when they have a terminating decimal expansion (and
;;;; within the output budget); floats print in a form that reads back to the
;;;; identical value.  Strings escape via the shared +JSON-SHORT-ESCAPES+ table.
(in-package #:json-kit)

;;; ---------------------------------------------------------------------
;;; JSON-number syntax check (for user encoders)
;;; ---------------------------------------------------------------------
(defun json-number-string-p (string)
  "True when STRING is syntactically a JSON number, used to validate the output
of a user NUMBER-ENCODER."
  (and (stringp string)
       (plusp (length string))
       (let ((index 0)
             (size (length string)))
         (labels ((current () (and (< index size) (char string index)))
                  (digits ()
                    (let ((start index))
                      (loop while (and (current)
                                       (let ((character (current)))
                                         (and character (char<= #\0 character #\9))))
                            do (incf index))
                      (> index start))))
           (when (eql (current) #\-) (incf index))
           (cond
             ((eql (current) #\0) (incf index))
             ((and (current) (find (current) "123456789" :test #'char=)) (digits))
             (t (return-from json-number-string-p nil)))
           (when (eql (current) #\.)
             (incf index)
             (unless (digits) (return-from json-number-string-p nil)))
           (when (and (current) (find (current) "eE" :test #'char=))
             (incf index)
             (when (and (current) (find (current) "+-" :test #'char=)) (incf index))
             (unless (digits) (return-from json-number-string-p nil)))
           (= index size)))))

;;; ---------------------------------------------------------------------
;;; Floats
;;; ---------------------------------------------------------------------
(defun finite-float-p (value)
  (declare (ignorable value))
  #+sbcl
  (not (or (sb-ext:float-nan-p value) (sb-ext:float-infinity-p value)))
  #-sbcl
  (and (= value value)
       (handler-case (progn (integer-decode-float value) t)
         (error () nil))))

(defun json-float-string (value)
  "A JSON representation of the finite float VALUE that reads back identically,
with the Lisp exponent marker (d/f/s/l) normalised to `e' and signed zero
preserved."
  (unless (finite-float-p value)
    (serialization-error "JSON numbers cannot represent NaN or infinity"))
  (if (zerop value)
      (if (minusp (float-sign value)) "-0.0" "0.0")
      (let* ((*print-readably* t)
             (*print-pretty* nil)
             (printed (write-to-string value))
             (marker (position-if
                      (lambda (character) (find character "dDfFsSlL" :test #'char=))
                      printed)))
        (if marker
            (concatenate 'string (subseq printed 0 marker) "e" (subseq printed (1+ marker)))
            printed))))

;;; ---------------------------------------------------------------------
;;; Integers and terminating ratios
;;; ---------------------------------------------------------------------
(defun decimal-digit-lower-bound (integer)
  "A conservative lower bound on the number of decimal digits INTEGER needs,
used to reject oversized output before the full conversion is done."
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
  "Return how many times FACTOR divides INTEGER and the remaining cofactor."
  (loop with count = 0
        while (zerop (mod integer factor))
        do (setf integer (/ integer factor))
           (incf count)
        finally (return (values count integer))))

(defun ratio-scale-lower-bound (denominator)
  (floor (1- (integer-length denominator)) 3))

(defun decimal-point-inserted-string (digits scale sign)
  "SIGN concatenated with DIGITS, its decimal point moved SCALE places in from
the right -- padding with leading zeros after \"0.\" when DIGITS is shorter
than SCALE."
  (if (zerop scale)
      (concatenate 'string sign digits)
      (let ((split (- (length digits) scale)))
        (if (plusp split)
            (concatenate 'string sign (subseq digits 0 split) "." (subseq digits split))
            (concatenate 'string sign "0." (make-string (- split) :initial-element #\0) digits)))))

(defun terminating-ratio-string (value)
  "A finite decimal string for the ratio VALUE, signalling if its expansion
does not terminate or would exceed the output budget."
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
          (decimal-point-inserted-string digits scale sign))))))

(defun write-json-number (value)
  "Serialize VALUE as a JSON number, via a user NUMBER-ENCODER when present
(whose result is validated to be a JSON number)."
  (let ((encoded
          (if *json-number-encoder*
              (funcall *json-number-encoder* value)
              (typecase value
                (integer
                 (ensure-integer-output-budget value)
                 (write-to-string value :base 10 :radix nil))
                (ratio (terminating-ratio-string value))
                (float (json-float-string value))
                (t (serialization-error "unsupported number type ~S" (type-of value)))))))
    (unless (json-number-string-p encoded)
      (serialization-error "number encoder returned an invalid JSON number"))
    (emit-string encoded)))

;;; ---------------------------------------------------------------------
;;; Strings
;;; ---------------------------------------------------------------------
(defun write-json-string (string)
  "Serialize STRING as a quoted, escaped JSON string, rejecting raw surrogates.
Contiguous unescaped characters are flushed as a single WRITE-STRING run and
only an escape or control character interrupts the run, so an ordinary string
costs one write rather than one per character."
  (declare (type string string))
  (emit-character #\")
  (let ((size (length string)))
    (declare (type fixnum size))
    (if (and (null *json-maximum-output-length*)
             (>= size 128)
             (loop for index fixnum below 16
                   for character = (char string index)
                   thereis (or (char= character #\")
                               (char= character #\\)))
             (>= (loop for index fixnum below 128
                       for character = (char string index)
                       count (or (char= character #\")
                                 (char= character #\\)))
                 12))
        (let* ((buffer-size (if (< size 4096) (* size 2) 8192))
               (buffer (make-string buffer-size))
               (used 0))
          (declare (type fixnum buffer-size used)
                   (type simple-string buffer))
          (labels ((flush-buffer ()
                     (unless (zerop used)
                       (if (or (null *json-maximum-output-length*)
                               (<= used (- *json-maximum-output-length*
                                           *json-output-count*)))
                           (progn
                             (reserve-output used)
                             (write-string buffer *json-output-stream* :end used))
                           (loop for index fixnum below used
                                 do (emit-character (schar buffer index))))
                       (setf used 0))))
            (loop for index fixnum below size
                  for character = (char string index)
                  for code fixnum = (char-code character)
                  do (cond
                       ((< code #x20)
                        (flush-buffer)
                        (let ((letter (json-escape-letter character)))
                          (if letter
                              (progn (emit-character #\\) (emit-character letter))
                              (progn
                                (reserve-output 6)
                                (write-string "\\u00" *json-output-stream*)
                                (write-char (schar "0123456789ABCDEF" (ash code -4))
                                            *json-output-stream*)
                                (write-char (schar "0123456789ABCDEF" (logand code #x0f))
                                            *json-output-stream*)))))
                       ((char= character #\")
                        (when (> used (- buffer-size 2))
                          (flush-buffer))
                        (setf (schar buffer used) #\\
                              (schar buffer (1+ used)) #\")
                        (incf used 2))
                       ((char= character #\\)
                        (when (> used (- buffer-size 2))
                          (flush-buffer))
                        (setf (schar buffer used) #\\
                              (schar buffer (1+ used)) #\\)
                        (incf used 2))
                       ((<= #xd800 code #xdfff)
                        (flush-buffer)
                        (serialization-error
                         "JSON strings cannot contain raw surrogate characters"))
                       (t
                        (when (= used buffer-size)
                          (flush-buffer))
                        (setf (schar buffer used) character)
                        (incf used))))
            (flush-buffer)))
        (let ((run-start 0))
          (declare (type fixnum run-start))
          (labels ((flush-run (end)
                     (when (< run-start end)
                       (let ((length (- end run-start)))
                         (if (or (null *json-maximum-output-length*)
                                 (<= length (- *json-maximum-output-length*
                                               *json-output-count*)))
                             (progn
                               (reserve-output length)
                               (write-string string *json-output-stream*
                                             :start run-start :end end))
                             (loop for index from run-start below end
                                   do (emit-character (char string index))))))))
            (loop for index below size
                  for character = (char string index)
                  for code = (char-code character)
                  do (cond
                       ((< code #x20)
                        (flush-run index)
                        (let ((letter (json-escape-letter character)))
                          (if letter
                              (progn (emit-character #\\) (emit-character letter))
                              (progn
                                (reserve-output 6)
                                (write-string "\\u00" *json-output-stream*)
                                (write-char (schar "0123456789ABCDEF" (ash code -4))
                                            *json-output-stream*)
                                (write-char (schar "0123456789ABCDEF" (logand code #x0f))
                                            *json-output-stream*))))
                        (setf run-start (1+ index)))
                       ((char= character #\") (flush-run index) (emit-string "\\\"")
                        (setf run-start (1+ index)))
                       ((char= character #\\) (flush-run index) (emit-string "\\\\")
                        (setf run-start (1+ index)))
                       ((<= #xd800 code #xdfff)
                        (flush-run index)
                        (serialization-error
                         "JSON strings cannot contain raw surrogate characters"))))
            (flush-run size)))))
  (emit-character #\"))
