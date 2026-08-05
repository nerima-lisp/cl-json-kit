;;;; src/writer-numbers.lisp
;;;;
;;;; Serializing JSON numbers.  Integers print exactly; ratios print only when
;;;; they have a terminating decimal expansion (and within the output budget);
;;;; floats print in a form that reads back to the identical value.
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
                      (loop while (and (current) (ascii-json-digit-p (current)))
                            do (incf index))
                      (> index start))))
           (when (eql (current) #\-) (incf index))
           (cond
             ((eql (current) #\0) (incf index))
             ((and (current) (char<= #\1 (current) #\9)) (digits))
             (t (return-from json-number-string-p nil)))
           (when (eql (current) #\.)
             (incf index)
             (unless (digits) (return-from json-number-string-p nil)))
           (when (member (current) +json-exponent-markers+)
             (incf index)
             (when (member (current) +json-sign-characters+) (incf index))
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

(defun float-format-name (value)
  "The type name naming VALUE's own float format, for binding
*READ-DEFAULT-FLOAT-FORMAT* around printing.  DOUBLE-FLOAT and SINGLE-FLOAT are
tested first so that implementations where SHORT-FLOAT or LONG-FLOAT is merely a
synonym for one of them (SBCL) still yield the canonical name."
  (etypecase value
    (double-float 'double-float)
    (single-float 'single-float)
    (short-float 'short-float)
    (long-float 'long-float)))

(defun json-float-string (value)
  "A JSON representation of the finite float VALUE that reads back identically,
with signed zero preserved.

The printer appends a Lisp exponent marker (d/f/s/l) whenever VALUE's format
differs from *READ-DEFAULT-FLOAT-FORMAT*, which would otherwise make this
library's output depend on ambient state of the calling image rather than on
VALUE alone: the same double serializes as \"3.14e0\" under the default
SINGLE-FLOAT setting and as \"3.14\" under DOUBLE-FLOAT.  Binding the variable to
VALUE's own format makes the output a function of VALUE.  The marker rewrite
below is kept as a fallback for implementations that print one regardless."
  (unless (finite-float-p value)
    (serialization-error "JSON numbers cannot represent NaN or infinity"))
  (if (zerop value)
      (if (minusp (float-sign value)) "-0.0" "0.0")
      (let* ((*print-readably* t)
             (*print-pretty* nil)
             (*read-default-float-format* (float-format-name value))
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
