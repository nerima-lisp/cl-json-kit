;;;; src/reader-numbers.lisp
;;;;
;;;; JSON numbers.  SCAN-NUMBER validates RFC 8259 grammar while collecting
;;;; sign, zero, and decimal-scale metadata for the range decoders.  Plain
;;;; integers are decoded by SCAN-INTEGER-FAST alone -- it never falls back to
;;;; SCAN-NUMBER without also being a float or a grammar error -- so
;;;; DECODE-FLOAT-RANGE (producing a double or, via EXACT-NUMBER-RANGE-VALUE,
;;;; an exact ratio) is SCAN-NUMBER's only decoder.  PARSE-NUMBER wires them
;;;; together and consults an optional user NUMBER-DECODER first.
(in-package #:json-kit)

(declaim (inline ascii-json-digit-p ascii-json-digit-value))

(defun ascii-json-digit-p (character)
  (and (characterp character) (char<= #\0 character #\9)))

(defun ascii-json-digit-value (character)
  (- (char-code character) (char-code #\0)))

;;; ---------------------------------------------------------------------
;;; Token analysis
;;; ---------------------------------------------------------------------
(defun scan-coefficient-digits (text start end negative-p)
  "The unsigned integer formed by TEXT[start,end)'s significant digits, skipping
the sign and decimal point and stopping before any exponent marker.  Shared by
EXACT-NUMBER-RANGE-VALUE and DECODE-FLOAT-RANGE so both decoders read the same
coefficient out of one number token."
  (let ((coefficient 0)
        (index (if negative-p (1+ start) start)))
    (loop while (< index end)
          for character = (char text index)
          until (member character +json-exponent-markers+)
          do (unless (char= character #\.)
               (setf coefficient (+ (* coefficient 10)
                                    (ascii-json-digit-value character))))
             (incf index))
    coefficient))

(defun exact-number-range-value
    (text start end negative-p coefficient-zero-p scale)
  "Return the exact rational value represented by TEXT[start,end)."
  (let* ((coefficient
           (if coefficient-zero-p
               0
               (scan-coefficient-digits text start end negative-p)))
         (magnitude
           (cond
             (coefficient-zero-p 0)
             ((minusp scale) (/ coefficient (expt 10 (- scale))))
             (t (* coefficient (expt 10 scale))))))
    (if negative-p (- magnitude) magnitude)))

;;; ---------------------------------------------------------------------
;;; Scanning and decoding
;;; ---------------------------------------------------------------------
(defun scan-number
    (state &optional resume-start resume-negative-p
                     resume-coefficient resume-coefficient-zero-p)
  "Validate a JSON number and return its range plus metadata needed for decoding."
  (let ((start (or resume-start (ps-pos state)))
        (floating-point-p (not (null resume-start)))
        (negative-p (if resume-start resume-negative-p nil))
        (coefficient-zero-p (if resume-start resume-coefficient-zero-p t))
        (coefficient (if resume-start resume-coefficient 0))
        (fractional-digits 0)
        (exponent 0)
        (exponent-negative-p nil)
        (exponent-overflow-p nil))
    (labels ((advance ()
               (when (>= (- (ps-pos state) start) (ps-max-number-length state))
                 (parse-error-here state "shorter number"))
               (ps-advance state))
             (coefficient-digits (fractional-p)
               (loop with count = 0
                     while (and (ps-peek state)
                                (ascii-json-digit-p (ps-peek state)))
                     for digit = (ascii-json-digit-value (ps-peek state))
                     do (setf coefficient (+ (* coefficient 10) digit))
                        (unless (zerop digit)
                          (setf coefficient-zero-p nil))
                        (when fractional-p (incf fractional-digits))
                        (advance)
                        (incf count)
                     finally (return count)))
             (require-coefficient-digits (fractional-p)
               (when (zerop (coefficient-digits fractional-p))
                 (parse-error-here state "decimal digit")))
             (exponent-digits ()
               (let* ((limit (+ (ps-max-exact-exponent state) fractional-digits))
                      (limit-quotient (floor limit 10))
                      (limit-remainder (mod limit 10)))
                 (loop with count = 0
                       while (and (ps-peek state)
                                  (ascii-json-digit-p (ps-peek state)))
                       for digit = (ascii-json-digit-value (ps-peek state))
                       do (unless (or coefficient-zero-p exponent-overflow-p)
                            (if (or (> exponent limit-quotient)
                                    (and (= exponent limit-quotient)
                                         (> digit limit-remainder)))
                                (setf exponent-overflow-p t)
                                (setf exponent (+ (* exponent 10) digit))))
                          (advance)
                          (incf count)
                       finally (return count)))))
      (unless resume-start
        (when (eql (ps-peek state) #\-)
          (setf negative-p t)
          (advance))
        (unless (and (ps-peek state) (ascii-json-digit-p (ps-peek state)))
          (parse-error-here state "decimal digit"))
        (if (eql (ps-peek state) #\0)
            (advance)
            (require-coefficient-digits nil)))
      (when (eql (ps-peek state) #\.)
        (setf floating-point-p t)
        (advance)
        (require-coefficient-digits t))
      (when (member (ps-peek state) +json-exponent-markers+)
        (setf floating-point-p t)
        (advance)
        (when (member (ps-peek state) +json-sign-characters+)
          (setf exponent-negative-p (eql (ps-peek state) #\-))
          (advance))
        (when (zerop (exponent-digits))
          (parse-error-here state "decimal digit")))
      (when exponent-negative-p (setf exponent (- exponent)))
      (let ((scale (- exponent fractional-digits)))
        (values start (ps-pos state) floating-point-p negative-p
                coefficient-zero-p coefficient scale
                (or coefficient-zero-p
                    (and (not exponent-overflow-p)
                         (<= (abs scale) (ps-max-exact-exponent state)))))))))

(defun decode-float-range
    (state text start end negative-p coefficient-zero-p coefficient scale scale-valid-p)
  "Decode TEXT[start,end) to a correctly rounded double, retaining exact extremes."
  (unless scale-valid-p
    (parse-error-here state "number scale within MAX-EXACT-EXPONENT"))
  (if coefficient-zero-p
      (if negative-p -0.0d0 0.0d0)
      (labels ((round-quotient-even (numerator denominator)
                 (multiple-value-bind (quotient remainder)
                     (floor numerator denominator)
                   (let ((twice-remainder (* 2 remainder)))
                     (if (or (> twice-remainder denominator)
                             (and (= twice-remainder denominator) (oddp quotient)))
                         (1+ quotient)
                         quotient))))
               (floor-log2-ratio (numerator denominator)
                 (let ((exponent (- (integer-length numerator)
                                    (integer-length denominator))))
                   (when (if (minusp exponent)
                             (< (ash numerator (- exponent)) denominator)
                             (< numerator (ash denominator exponent)))
                     (decf exponent))
                   exponent))
               (scaled-rounded (numerator denominator shift)
                 (if (minusp shift)
                     (round-quotient-even numerator (ash denominator (- shift)))
                     (round-quotient-even (ash numerator shift) denominator))))
        (handler-case
            (let* ((power (expt 10 (abs scale)))
                   (numerator (if (minusp scale) coefficient (* coefficient power)))
                   (denominator (if (minusp scale) power 1))
                   (binary-exponent (floor-log2-ratio numerator denominator))
                   (rounded
                     (if (< binary-exponent -1022)
                         (scaled-rounded numerator denominator 1074)
                         (scaled-rounded numerator denominator (- 52 binary-exponent)))))
              (cond
                ((or (> binary-exponent 1023) (zerop rounded))
                 (exact-number-range-value text start end negative-p
                                           coefficient-zero-p scale))
                ((< binary-exponent -1022)
                 (let ((value (scale-float (float rounded 1.0d0) -1074)))
                   (if negative-p (- value) value)))
                (t
                 (when (= rounded (ash 1 53))
                   (setf rounded (ash 1 52))
                   (incf binary-exponent))
                 (if (> binary-exponent 1023)
                     (exact-number-range-value text start end negative-p
                                               coefficient-zero-p scale)
                     (let ((value (scale-float (float rounded 1.0d0)
                                               (- binary-exponent 52))))
                       (if negative-p (- value) value))))))
          (error ()
            (exact-number-range-value text start end negative-p
                                      coefficient-zero-p scale))))))

(defun scan-integer-fast (state)
  "Fast path for a plain JSON integer parsed without a NUMBER-DECODER: scan it
directly and return its exact value, accumulating a FIXNUM until it would
overflow and only then widening to a bignum, so the overwhelmingly common
integer case never allocates a token string.

Returns NIL, leaving the cursor untouched, for malformed or over-long input so
SCAN-NUMBER remains the source of grammar validation and diagnostics. For a
token continuing into a float, returns NIL plus continuation metadata while
leaving the cursor at the decimal point or exponent marker."
  (let* ((text (ps-text state))
         (length (ps-length state))
         (start (ps-pos state))
         (limit (min length (+ start (ps-max-number-length state))))
         (position start)
         (negative-p nil)
         (fixnum-cutoff (load-time-value (floor most-positive-fixnum 10)))
         (fixnum-remainder (load-time-value (mod most-positive-fixnum 10)))
         (fixnum-value 0)
         (value 0)
         (overflow-p nil))
    (declare (type simple-string text)
             (type fixnum length start limit position fixnum-cutoff fixnum-remainder
                   fixnum-value)
             (type unsigned-byte value))
    (flet ((fall-back ()
             (setf (ps-pos state) start)
             (return-from scan-integer-fast nil)))
      (when (and (< position length) (char= (schar text position) #\-))
        (setf negative-p t)
        (incf position))
      (unless (and (< position length) (char<= #\0 (schar text position) #\9))
        (fall-back))
      (cond
        ((char= (schar text position) #\0)
         (when (>= position limit) (fall-back))
         (incf position))
        (t
         (loop while (< position length)
               for code fixnum = (char-code (schar text position))
               while (<= #x30 code #x39)
               for digit fixnum = (- code #x30)
               do (when (>= position limit) (fall-back))
                  (if (or (< fixnum-value fixnum-cutoff)
                          (and (= fixnum-value fixnum-cutoff)
                               (<= digit fixnum-remainder)))
                      (setf fixnum-value
                            (the fixnum (+ (the fixnum (* fixnum-value 10)) digit)))
                      (progn
                        (setf overflow-p t
                              value (+ (* fixnum-value 10) digit))
                        (incf position)
                        (loop while (< position length)
                              for rest-code fixnum = (char-code (schar text position))
                              while (<= #x30 rest-code #x39)
                              do (when (>= position limit) (fall-back))
                                 (setf value (+ (* value 10) (- rest-code #x30)))
                                 (incf position))
                        (return)))
                  (incf position))
         (unless overflow-p (setf value fixnum-value))))
      (when (< position length)
        (let ((next (schar text position)))
          (when (or (char= next #\.) (char= next #\e) (char= next #\E))
            (setf (ps-pos state) position)
            (return-from scan-integer-fast
              (values nil t start negative-p value (zerop value))))))
      (setf (ps-pos state) position)
      (if negative-p (- value) value))))

(defun parse-number (state)
  "Parse a JSON number, allocating a raw token only for NUMBER-DECODER."
  (if (ps-number-decoder state)
      (multiple-value-bind
            (start end floating-point-p negative-p coefficient-zero-p coefficient scale scale-valid-p)
          (scan-number state)
        (declare (ignore negative-p coefficient-zero-p coefficient scale scale-valid-p))
        (let ((token (subseq (ps-text state) start end)))
          (with-json-callback (value state "NUMBER-DECODER"
                                     (ps-number-decoder state) token
                                     (not floating-point-p))
            value)))
      (multiple-value-bind
            (integer-value float-continuation-p start negative-p coefficient coefficient-zero-p)
          (scan-integer-fast state)
        (cond
          (integer-value integer-value)
          (float-continuation-p
           (multiple-value-bind
                 (range-start end floating-point-p range-negative-p range-zero-p
                              range-coefficient scale scale-valid-p)
               (scan-number state start negative-p coefficient coefficient-zero-p)
             (declare (ignore floating-point-p))
             (decode-float-range state (ps-text state) range-start end range-negative-p
                                 range-zero-p range-coefficient scale scale-valid-p)))
          (t
           (multiple-value-bind
                 (range-start end floating-point-p range-negative-p range-zero-p
                              range-coefficient scale scale-valid-p)
               (scan-number state)
             (declare (ignore floating-point-p))
             (decode-float-range state (ps-text state) range-start end range-negative-p
                                 range-zero-p range-coefficient scale scale-valid-p)))))))
