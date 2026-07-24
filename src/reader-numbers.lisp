;;;; src/reader-numbers.lisp
;;;;
;;;; JSON numbers.  Reading a number is three separable jobs, one function
;;;; each: SCAN-NUMBER validates the RFC 8259 grammar and returns the raw
;;;; token, NUMBER-TOKEN-PROPERTIES derives sign/zero/scale (and enforces the
;;;; exact-exponent bound), and the DECODE-*-TOKEN pair turns a token into a
;;;; Lisp integer, ratio, or double-float.  PARSE-NUMBER just wires them
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
(defun number-token-properties (state token)
  "Return (VALUES NEGATIVE-P COEFFICIENT-ZERO-P SCALE) for the scanned numeric
TOKEN, where SCALE is the power of ten the integer coefficient is multiplied
by.  Signals when the effective scale would exceed MAX-EXACT-EXPONENT, scanning
the exponent digit by digit so an enormous exponent literal cannot overflow
before the bound is checked."
  (let* ((length (length token))
         (negative-p (char= (char token 0) #\-))
         (mantissa-start (if negative-p 1 0))
         (exponent-position (or (position #\e token :test #'char-equal) length))
         (point-position (position #\. token :end exponent-position))
         (fractional-digits
           (if point-position (- exponent-position point-position 1) 0))
         (coefficient-zero-p t)
         (exponent 0)
         (exponent-negative-p nil)
         (exponent-limit (+ (ps-max-exact-exponent state) fractional-digits)))
    (loop for index from mantissa-start below exponent-position
          for character = (char token index)
          unless (char= character #\.)
            do (unless (char= character #\0)
                 (setf coefficient-zero-p nil)))
    (when (< exponent-position length)
      (let ((index (1+ exponent-position)))
        (when (member (char token index) '(#\+ #\-))
          (setf exponent-negative-p (char= (char token index) #\-))
          (incf index))
        (loop while (< index length)
              for digit = (ascii-json-digit-value (char token index))
              do (unless coefficient-zero-p
                   (when (or (> exponent (floor exponent-limit 10))
                             (and (= exponent (floor exponent-limit 10))
                                  (> digit (mod exponent-limit 10))))
                     (parse-error-here state "number scale within MAX-EXACT-EXPONENT"))
                   (setf exponent (+ (* exponent 10) digit)))
                 (incf index))))
    (when exponent-negative-p
      (setf exponent (- exponent)))
    (let ((scale (- exponent fractional-digits)))
      (unless coefficient-zero-p
        (when (> (abs scale) (ps-max-exact-exponent state))
          (parse-error-here state "number scale within MAX-EXACT-EXPONENT")))
      (values negative-p coefficient-zero-p scale))))

(defun exact-number-value (state token)
  "The exact rational value of TOKEN, used when a platform float read would
lose precision (very large or very small magnitudes)."
  (multiple-value-bind (negative-p coefficient-zero-p scale)
      (number-token-properties state token)
    (let ((coefficient 0)
          (mantissa-start (if negative-p 1 0))
          (exponent-position
            (or (position #\e token :test #'char-equal) (length token))))
      (unless coefficient-zero-p
        (loop for index from mantissa-start below exponent-position
              for character = (char token index)
              unless (char= character #\.)
                do (setf coefficient
                         (+ (* coefficient 10) (ascii-json-digit-value character)))))
      (let ((magnitude
              (cond
                (coefficient-zero-p 0)
                ((minusp scale) (/ coefficient (expt 10 (- scale))))
                (t (* coefficient (expt 10 scale))))))
        (if negative-p (- magnitude) magnitude)))))

;;; ---------------------------------------------------------------------
;;; Scanning and decoding
;;; ---------------------------------------------------------------------
(defun scan-number (state)
  "Validate a JSON number at the cursor and return (VALUES TOKEN FLOATING-P),
advancing past it.  Enforces MAX-NUMBER-LENGTH as each character is consumed."
  (let ((start (ps-pos state))
        (floating-point-p nil))
    (labels ((advance ()
               (when (>= (- (ps-pos state) start) (ps-max-number-length state))
                 (parse-error-here state "shorter number"))
               (ps-advance state))
             (digits ()
               (loop with count = 0
                     while (and (ps-peek state) (ascii-json-digit-p (ps-peek state)))
                     do (advance) (incf count)
                     finally (return count)))
             (require-digits ()
               (when (zerop (digits))
                 (parse-error-here state "decimal digit"))))
      (when (eql (ps-peek state) #\-) (advance))
      (unless (and (ps-peek state) (ascii-json-digit-p (ps-peek state)))
        (parse-error-here state "decimal digit"))
      (if (eql (ps-peek state) #\0) (advance) (require-digits))
      (when (eql (ps-peek state) #\.)
        (setf floating-point-p t)
        (advance)
        (require-digits))
      (when (member (ps-peek state) '(#\e #\E))
        (setf floating-point-p t)
        (advance)
        (when (member (ps-peek state) '(#\+ #\-)) (advance))
        (require-digits))
      (values (subseq (ps-text state) start (ps-pos state)) floating-point-p))))

(defun decode-integer-token (token)
  "The exact integer value of an integer TOKEN."
  (let ((value 0)
        (index 0)
        (negative-p nil))
    (when (char= (char token 0) #\-)
      (setf negative-p t)
      (incf index))
    (loop while (< index (length token))
          do (setf value (+ (* value 10) (ascii-json-digit-value (char token index))))
             (incf index))
    (if negative-p (- value) value)))

(defun decode-float-token (state token)
  "Decode a floating-point TOKEN, preferring a native double-float read but
falling back to an exact rational when the read is lossy or the magnitude is
out of float range.  Signed zero is preserved."
  (multiple-value-bind (negative-p coefficient-zero-p)
      (number-token-properties state token)
    (if coefficient-zero-p
        (if negative-p -0.0d0 0.0d0)
        (let ((*read-default-float-format* 'double-float)
              (*read-eval* nil))
          (handler-case
              (multiple-value-bind (value consumed) (read-from-string token nil nil)
                (if (and value (= consumed (length token)))
                    (handler-case
                        (progn
                          (rational value)
                          (if (zerop value) (exact-number-value state token) value))
                      (error () (exact-number-value state token)))
                    (parse-error-here state "JSON number")))
            (error () (exact-number-value state token)))))))

(defun parse-number (state)
  "Parse a JSON number, honouring a user NUMBER-DECODER when present."
  (multiple-value-bind (token floating-point-p) (scan-number state)
    (cond
      ((ps-number-decoder state)
       (with-json-callback (value state "NUMBER-DECODER"
                                  (ps-number-decoder state) token (not floating-point-p))
         value))
      (floating-point-p (decode-float-token state token))
      (t (decode-integer-token token)))))
