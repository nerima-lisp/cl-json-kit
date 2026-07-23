;;;; src/reader.lisp
;;;;
;;;; A recursive-descent JSON parser.
;;;;
;;;; Design note (the whole point of this library): PARSE-OBJECT always reads
;;;; "{...}" as a sequence of key/value pairs and PARSE-ARRAY always reads
;;;; "[...]" as a sequence of values.  Whether those pairs end up as a
;;;; HASH-TABLE or an ALIST, and whether that sequence of values ends up as a
;;;; SIMPLE-VECTOR or a LIST, is decided once, at the very end of each of
;;;; those two functions, purely from the :OBJECT-TYPE / :ARRAY-TYPE
;;;; arguments given to PARSE.  Nothing downstream ever inspects the shape of
;;;; already-built Lisp data to *guess* whether it "looks like" an object or
;;;; an array -- that guess is exactly the ambiguity bug this library exists
;;;; to avoid.
(in-package #:json-kit)

(progn
(defstruct (json-sentinel (:constructor make-json-sentinel (name)) (:copier nil) (:predicate nil)) (name nil :read-only t))
(defvar +json-null+ (make-json-sentinel :null))
(defvar +json-false+ (make-json-sentinel :false))
(defun json-null-p (value) (eq value +json-null+))
(defun json-false-p (value) (eq value +json-false+))
(defstruct (parser-state (:conc-name ps-))
  (text "" :type simple-string)
  (length 0 :type fixnum)
  (pos 0 :type fixnum)
  (object-type :hash-table)
  (array-type :vector)
  (key-type :string)
  (duplicate-key-policy :last)
  null-value false-value (true-value t)
  key-decoder number-decoder object-hook array-hook path
  (depth 0 :type fixnum)
  (max-depth 512 :type integer)
  (max-string-length 1048576 :type integer)
  (max-number-length 1024 :type integer)
  (max-exact-exponent 10000 :type integer)
  (max-array-elements 1000000 :type integer)
  (max-object-members 1000000 :type integer)
  (context "json")))

(declaim (inline ps-eof-p ps-peek ps-advance))

(defun ps-eof-p (state)
  (>= (ps-pos state) (ps-length state)))

(defun ps-peek (state &optional (offset 0))
  (let ((index (+ (ps-pos state) offset)))
    (when (< index (ps-length state))
      (char (ps-text state) index))))

(defun ps-advance (state)
  (incf (ps-pos state)))

(defun parse-error-location (text position)
  (let ((line 1) (column 1))
    (loop for index below position
          for character = (char text index)
          do (cond
               ((char= character #\Return)
                (incf line)
                (setf column 1))
               ((char= character #\Newline)
                (unless (and (plusp index)
                             (char= (char text (1- index)) #\Return))
                  (incf line)
                  (setf column 1)))
               (t (incf column))))
    (values line column)))

(defun parse-error-here (state &optional expected)
  (multiple-value-bind (line column)
      (parse-error-location (ps-text state) (ps-pos state))
    (error (quote json-parse-error)
           :position (ps-pos state) :line line :column column
           :path (reverse (ps-path state)) :expected expected
           :context (ps-context state)
           :text (safe-diagnostic-snippet (ps-text state)))))

(defun whitespace-char-p (c)
  (and c (member c '(#\Space #\Tab #\Newline #\Return #\Linefeed) :test #'char=)))

(defun skip-whitespace (state)
  (loop while (whitespace-char-p (ps-peek state))
        do (ps-advance state)))

(defun expect-char (state expected)
  (unless (eql (ps-peek state) expected)
    (parse-error-here state))
  (ps-advance state))

(defun parse-value (state)
  (skip-whitespace state)
  (let ((c (ps-peek state)))
    (unless c (parse-error-here state "JSON value"))
    (cond
      ((char= c #\") (parse-json-string state))
      ((char= c #\{) (parse-object state))
      ((char= c #\[) (parse-array state))
      ((or (ascii-json-digit-p c) (char= c #\-)) (parse-number state))
      ((char= c #\t) (parse-literal state "true" (ps-true-value state)))
      ((char= c #\f) (parse-literal state "false" (ps-false-value state)))
      ((char= c #\n) (parse-literal state "null" (ps-null-value state)))
      (t (parse-error-here state "JSON value")))))

(defun parse-literal (state token value) (let* ((start (ps-pos state)) (end (+ start (length token)))) (when (or (> end (ps-length state)) (string/= (ps-text state) token :start1 start :end1 end)) (parse-error-here state token)) (setf (ps-pos state) end) value))

;;; ---------------------------------------------------------------------
;;; Strings
;;; ---------------------------------------------------------------------
(defun hex-digit-value (c) (cond ((char<= #\0 c #\9) (- (char-code c) (char-code #\0))) ((char<= #\A c #\F) (+ 10 (- (char-code c) (char-code #\A)))) ((char<= #\a c #\f) (+ 10 (- (char-code c) (char-code #\a)))) (t nil)))

(defun parse-hex4 (state)
  "Read exactly 4 hex digits starting at the current position and return the
integer they encode, advancing past them."
  (let ((code 0))
    (dotimes (i 4 code)
      (let* ((c (ps-peek state))
             (digit (and c (hex-digit-value c))))
        (unless digit
          (parse-error-here state))
        (setf code (+ (* code 16) digit))
        (ps-advance state)))))

(defun parse-unicode-escape (state)
  "Called with the position right after the \\u of an escape sequence has
already been consumed by the caller.  Handles UTF-16 surrogate pairs
(high surrogate U+D800-U+DBFF followed by a \\uXXXX low surrogate
U+DC00-U+DFFF) so that characters outside the Basic Multilingual Plane
(e.g. emoji) decode into a single Lisp character."
  (let ((code (parse-hex4 state)))
    (cond
      ((<= #xD800 code #xDBFF)
       ;; High surrogate: a low surrogate escape must follow immediately.
       (unless (and (eql (ps-peek state) #\\) (eql (ps-peek state 1) #\u))
         (parse-error-here state))
       (ps-advance state)
       (ps-advance state)
       (let ((low (parse-hex4 state)))
         (unless (<= #xDC00 low #xDFFF)
           (parse-error-here state))
         (code-char (+ #x10000
                        (ash (- code #xD800) 10)
                        (- low #xDC00)))))
      ((<= #xDC00 code #xDFFF)
       ;; Lone low surrogate with no preceding high surrogate.
       (parse-error-here state))
      (t (code-char code)))))

(defun parse-json-string (state)
  "Parse a JSON string, using a direct substring fast path when no decoding is needed."
  (expect-char state #\")
  (let ((start (ps-pos state))
        (decoded-length 0))
    (loop while (not (ps-eof-p state))
          for c = (ps-peek state)
          for code = (char-code c)
          do (cond
        ((char= c #\")
          (ps-advance state)
          (return-from
            parse-json-string
            (subseq (ps-text state) start (1- (ps-pos state)))))
        ((or (char= c #\\) (< code #x20) (<= #xD800 code #xDFFF)) (return))
        (t
          (when (>= (- (ps-pos state) start) (ps-max-string-length state))
            (parse-error-here state))
          (ps-advance state))))
    (when (ps-eof-p state)
      (parse-error-here state))
    (setf decoded-length (- (ps-pos state) start))
    (with-output-to-string (out)
      (write-string (ps-text state) out :start start :end (ps-pos state))
      (labels ((emit (character)
                 (when (>= decoded-length (ps-max-string-length state))
              (parse-error-here state))
                 (incf decoded-length)
                 (write-char character out)))
        (loop (when (ps-eof-p state)
            (parse-error-here state)) (let* ((c (ps-peek state))
                 (code (char-code c)))
            (cond
              ((char= c #\")
                (ps-advance state)
                (return))
              ((char= c #\\)
                (ps-advance state)
                (when (ps-eof-p state)
                  (parse-error-here state))
                (let ((e (ps-peek state)))
                  (case e
                    (#\"
                      (ps-advance state)
                      (emit #\"))
                    (#\\
                      (ps-advance state)
                      (emit #\\))
                    (#\/
                      (ps-advance state)
                      (emit #\/))
                    (#\b
                      (ps-advance state)
                      (emit #\Backspace))
                    (#\f
                      (ps-advance state)
                      (emit #\Page))
                    (#\n
                      (ps-advance state)
                      (emit #\Newline))
                    (#\r
                      (ps-advance state)
                      (emit #\Return))
                    (#\t
                      (ps-advance state)
                      (emit #\Tab))
                    (#\u
                      (ps-advance state)
                      (emit (parse-unicode-escape state)))
                    (t (parse-error-here state)))))
              ((or (< code #x20) (<= #xD800 code #xDFFF)) (parse-error-here state))
              (t
                (ps-advance state)
                (emit c)))))))))

;;; ---------------------------------------------------------------------
;;; Numbers
;;; ---------------------------------------------------------------------
(progn
  (defun ascii-json-digit-p (character)
    (and (characterp character) (char<= #\0 character #\9)))

  (defun ascii-json-digit-value (character)
    (- (char-code character) (char-code #\0)))

  (defun consume-digits (state)
    "Advance past a (possibly empty) run of decimal digits and return how many were consumed."
    (let ((start (ps-pos state)))
      (loop while (and (ps-peek state) (ascii-json-digit-p (ps-peek state)))
            do (ps-advance state))
      (- (ps-pos state) start))))

(defun require-at-least-one-digit (state)
  (when (zerop (consume-digits state))
    (parse-error-here state)))

(defun parse-number (state)
  (let ((start (ps-pos state))
        (floating-point-p nil))
    (labels ((advance ()
               (when (>= (- (ps-pos state) start) (ps-max-number-length state))
                 (parse-error-here state "shorter number"))
               (ps-advance state))
             (digits ()
               (let ((count 0))
                 (loop while (and (ps-peek state) (ascii-json-digit-p (ps-peek state)))
                       do (advance) (incf count))
                 count))
             (require-digits ()
               (when (zerop (digits))
                 (parse-error-here state "decimal digit")))
             (number-properties (token)
               (let* ((length (length token))
                      (negative-p (char= (char token 0) #\-))
                      (mantissa-start (if negative-p 1 0))
                      (exponent-position
                        (or (position #\e token :test (function char-equal)) length))
                      (point-position (position #\. token :end exponent-position))
                      (fractional-digits
                        (if point-position (- exponent-position point-position 1) 0))
                      (coefficient-zero-p t)
                      (exponent 0)
                      (exponent-negative-p nil)
                      (exponent-limit
                        (+ (ps-max-exact-exponent state) fractional-digits)))
                 (loop for index from mantissa-start below exponent-position
                       for character = (char token index)
                       unless (char= character #\.)
                         do (unless (char= character #\0)
                              (setf coefficient-zero-p nil)))
                 (when (< exponent-position length)
                   (let ((index (1+ exponent-position)))
                     (when (member (char token index) (list #\+ #\-))
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
         (incf index))
))
                 (when exponent-negative-p
                   (setf exponent (- exponent)))
                 (let ((scale (- exponent fractional-digits)))
                   (unless coefficient-zero-p
                     (when (> (abs scale) (ps-max-exact-exponent state))
                       (parse-error-here
                         state "number scale within MAX-EXACT-EXPONENT")))
                   (values negative-p coefficient-zero-p scale))))
             (exact-value (token)
               (multiple-value-bind (negative-p coefficient-zero-p scale)
                   (number-properties token)
                 (let ((coefficient 0)
                       (mantissa-start (if negative-p 1 0))
                       (exponent-position
                         (or (position #\e token :test (function char-equal))
                             (length token))))
                   (unless coefficient-zero-p
                     (loop for index from mantissa-start below exponent-position
                           for character = (char token index)
                           unless (char= character #\.)
                             do (setf coefficient
                                      (+ (* coefficient 10)
                                         (ascii-json-digit-value character)))))
                   (let ((magnitude
                           (cond
                             (coefficient-zero-p 0)
                             ((minusp scale) (/ coefficient (expt 10 (- scale))))
                             (t (* coefficient (expt 10 scale))))))
                     (if negative-p (- magnitude) magnitude))))))
      (when (eql (ps-peek state) #\-) (advance))
      (unless (and (ps-peek state) (ascii-json-digit-p (ps-peek state)))
        (parse-error-here state "decimal digit"))
      (if (eql (ps-peek state) #\0) (advance) (require-digits))
      (when (eql (ps-peek state) #\.)
        (setf floating-point-p t)
        (advance)
        (require-digits))
      (when (member (ps-peek state) (list #\e #\E))
        (setf floating-point-p t)
        (advance)
        (when (member (ps-peek state) (list #\+ #\-)) (advance))
        (require-digits))
      (let ((token (subseq (ps-text state) start (ps-pos state))))
        (when (ps-number-decoder state)
          (return-from parse-number
            (call-parser-callback state "NUMBER-DECODER"
                                  (ps-number-decoder state) token
                                  (not floating-point-p))))
        (if floating-point-p
            (multiple-value-bind (negative-p coefficient-zero-p)
                (number-properties token)
              (when coefficient-zero-p
                (return-from parse-number (if negative-p -0.0d0 0.0d0)))
              (let ((*read-default-float-format* (quote double-float))
                    (*read-eval* nil))
                (handler-case
                    (multiple-value-bind (value consumed)
                        (read-from-string token nil nil)
                      (if (and value (= consumed (length token)))
                          (handler-case
                              (progn (rational value) (if (zerop value) (exact-value token) value))
                            (error () (exact-value token)))
                          (parse-error-here state "JSON number")))
                  (error () (exact-value token)))))
            (let ((value 0) (index start) (negative-p nil))
              (when (char= (char (ps-text state) index) #\-)
                (setf negative-p t)
                (incf index))
              (loop while (< index (ps-pos state))
                    do (setf value (+ (* value 10)
                                     (ascii-json-digit-value
                                       (char (ps-text state) index))))
                       (incf index))
              (if negative-p (- value) value)))))))


;;; ---------------------------------------------------------------------
;;; Objects and arrays
;;; ---------------------------------------------------------------------
(defstruct (json-object
               (:constructor %make-json-object (members))
               (:copier nil)
               (:conc-name %json-object-))
    (members nil :type list :read-only t))

(progn
  (defun call-parser-callback (state callback function &rest arguments)
    (handler-case
        (apply function arguments)
      (json-parse-error (condition)
        (error condition))
      (error (condition)
        (let ((diagnostic
                (handler-case
                    (safe-diagnostic-snippet
                      (format nil "~A: ~A" (type-of condition) condition))
                  (error ()
                    (safe-diagnostic-snippet (type-of condition))))))
          (parse-error-here
            state
            (format nil "successful ~A callback (cause: ~A)"
                    callback diagnostic))))))

  (defun json-key->lisp-key (key-string state) (if (ps-key-decoder state) (let ((converted-key (call-parser-callback state "KEY-DECODER" (ps-key-decoder state) key-string))) (unless (stringp converted-key) (parse-error-here state "KEY-DECODER callback returning a string")) converted-key) key-string)))

(defun assemble-object (pairs object-type)
  "PAIRS is a list of (LISP-KEY . VALUE) conses collected while reading
\"{...}\".  This is the single place that decides HASH-TABLE vs ALIST -- the
decision is made once, from OBJECT-TYPE, never inferred later."
  (ecase object-type
    (:alist pairs)
    (:hash-table
      (let ((table (make-hash-table :test #'equal)))
        (dolist (pair pairs table)
          (setf (gethash (car pair) table) (cdr pair)))))))

(defun assemble-array (elements array-type)
  "ELEMENTS is a list of values collected while reading \"[...]\".  This is
the single place that decides SIMPLE-VECTOR vs LIST."
  (ecase array-type
    (:list elements)
    (:vector (coerce elements 'simple-vector))))

(defun parse-object (state)
  (when (>= (ps-depth state) (ps-max-depth state))
    (parse-error-here state "shallower nesting"))
  (incf (ps-depth state))
  (unwind-protect
       (progn
         (expect-char state #\{)
         (skip-whitespace state)
         (let ((result (if (eq (ps-object-type state) :hash-table)
                           (make-hash-table :test (function equal))
                           nil))
               (seen (make-hash-table :test (function equal)))
               (count 0))
           (unless (eql (ps-peek state) #\})
             (loop
               (when (>= count (ps-max-object-members state))
                 (parse-error-here state "fewer object members"))
               (incf count)
               (skip-whitespace state)
               (unless (eql (ps-peek state) #\")
                 (parse-error-here state "object key string"))
               (let* ((key (parse-json-string state))
                      (old-path (ps-path state))
                      (converted-key nil))
                 (setf (ps-path state) (cons key old-path))
                 (unwind-protect
                      (setf converted-key (json-key->lisp-key key state))
                   (setf (ps-path state) old-path))
                 (multiple-value-bind (prior present-p) (gethash converted-key seen)
                   (when (and present-p (eq (ps-duplicate-key-policy state) :error))
                     (setf (ps-path state) (cons key old-path))
                     (unwind-protect
                          (parse-error-here state "unique object key")
                       (setf (ps-path state) old-path)))
                   (skip-whitespace state)
                   (expect-char state #\:)
                   (skip-whitespace state)
                   (let ((value nil))
                     (setf (ps-path state) (cons key old-path))
                     (unwind-protect
                          (setf value (parse-value state))
                       (setf (ps-path state) old-path))
                     (case (ps-duplicate-key-policy state)
                       (:preserve (push (cons converted-key value) result))
                       (:first
                        (unless present-p
                          (if (eq (ps-object-type state) :alist)
                              (let ((pair (cons converted-key value)))
                                (push pair result)
                                (setf (gethash converted-key seen) pair))
                              (progn
                                (setf (gethash converted-key result) value)
                                (setf (gethash converted-key seen) t)))))
                       ((:last :error)
                        (if (eq (ps-object-type state) :alist)
                            (if present-p
                                (setf (cdr prior) value)
                                (let ((pair (cons converted-key value)))
                                  (push pair result)
                                  (setf (gethash converted-key seen) pair)))
                            (progn
                              (setf (gethash converted-key result) value)
                              (setf (gethash converted-key seen) t)))))))
                 (skip-whitespace state)
                 (let ((c (ps-peek state)))
                   (cond
                     ((eql c #\,)
                      (ps-advance state)
                      (skip-whitespace state)
                      (when (eql (ps-peek state) #\})
                        (parse-error-here state "object member")))
                     ((eql c #\}) (return))
                     (t (parse-error-here state "comma or closing brace")))))))
           (expect-char state #\})
           (let ((object (if (eq (ps-object-type state) :alist)
                             (nreverse result)
                             result)))
             (if (ps-object-hook state)
                 (call-parser-callback state "OBJECT-HOOK" (ps-object-hook state) object)
                 object))))
    (decf (ps-depth state))))

(defun parse-array (state)
  (when (>= (ps-depth state) (ps-max-depth state))
    (parse-error-here state "shallower nesting"))
  (incf (ps-depth state))
  (unwind-protect
       (progn
         (expect-char state #\[)
         (skip-whitespace state)
         (let ((elements (if (eq (ps-array-type state) :vector)
                             (make-array 0 :adjustable t :fill-pointer 0)
                             nil))
               (count 0))
           (unless (eql (ps-peek state) #\])
             (loop
               (when (>= count (ps-max-array-elements state))
                 (parse-error-here state "fewer array elements"))
               (skip-whitespace state)
               (let ((old-path (ps-path state))
                     (value nil))
                 (setf (ps-path state) (cons count old-path))
                 (unwind-protect
                      (setf value (parse-value state))
                   (setf (ps-path state) old-path))
                 (if (eq (ps-array-type state) :vector)
                     (vector-push-extend value elements)
                     (push value elements)))
               (incf count)
               (skip-whitespace state)
               (let ((c (ps-peek state)))
                 (cond
                   ((eql c #\,)
                    (ps-advance state)
                    (skip-whitespace state)
                    (when (eql (ps-peek state) #\])
                      (parse-error-here state "array value")))
                   ((eql c #\]) (return))
                   (t (parse-error-here state "comma or closing bracket"))))))
           (expect-char state #\])
           (let ((array (if (eq (ps-array-type state) :vector)
                            (coerce elements (quote simple-vector))
                            (nreverse elements))))
             (if (ps-array-hook state)
                 (call-parser-callback state "ARRAY-HOOK" (ps-array-hook state) array)
                 array))))
    (decf (ps-depth state))))

;;; ---------------------------------------------------------------------
;;; Public entry point
;;; ---------------------------------------------------------------------
(defun validate-timeout-seconds (timeout-seconds context text) (unless (or (null timeout-seconds) (and (realp timeout-seconds) (not (minusp timeout-seconds)))) (error (quote json-parse-error) :position 0 :line 1 :column 1 :path nil :expected "TIMEOUT-SECONDS to be NIL or a non-negative real" :context context :text (safe-diagnostic-snippet text))))



(defun read-json (stream &rest options &key (max-input-length 16777216) &allow-other-keys)
  "Read exactly one JSON value from STREAM without seeking or consuming a following value."
  (let ((buffer (make-array 0 :element-type (quote character)
                              :adjustable t :fill-pointer 0))
        (eof (gensym "EOF"))
        (timeout-seconds (getf options :timeout-seconds)))
    (labels ((fail (expected)
               (let ((text (coerce buffer (quote string))))
                 (multiple-value-bind (line column)
                     (parse-error-location text (length text))
                   (error 'json-parse-error :position (length text) :line line :column column :path nil :expected expected :context "stream" :text (safe-diagnostic-snippet text)))))
             (peek () (peek-char nil stream nil eof))
             (take ()
               (when (>= (length buffer) max-input-length)
                 (fail "input within MAX-INPUT-LENGTH"))
               (vector-push-extend (read-char stream) buffer))
             (take-count (count)
               (loop repeat count
                     until (eq (peek) eof)
                     do (take)))
             (take-string ()
               (take)
               (let ((escaped nil))
                 (loop for character = (peek)
                       until (eq character eof)
                       do (take)
                          (cond
                            (escaped (setf escaped nil))
                            ((char= character #\\) (setf escaped t))
                            ((char= character #\") (return))))))
             (take-container ()
               (let ((closers (list (if (char= (peek) #\{) #\} #\])))
                     (in-string nil)
                     (escaped nil))
                 (take)
                 (loop for character = (peek) while closers until (eq character eof) do (take) (cond (in-string (cond (escaped (setf escaped nil)) ((char= character #\\) (setf escaped t)) ((char= character #\") (setf in-string nil)))) ((char= character #\") (setf in-string t)) ((char= character #\{) (push #\} closers)) ((char= character #\[) (push #\] closers)) ((member character (list #\} #\])) (if (char= character (first closers)) (pop closers) (return)))))))
             (take-number ()
               (when (and (characterp (peek)) (char= (peek) #\-))
                 (take))
               (let ((character (peek)))
                 (cond
                   ((and (characterp character) (char= character #\0))
                    (take))
                   ((and (characterp character) (char<= #\1 character #\9))
                    (loop for digit = (peek)
                          while (and (characterp digit) (ascii-json-digit-p digit))
                          do (take)))))
               (when (and (characterp (peek)) (char= (peek) #\.))
                 (take)
                 (loop for digit = (peek)
                       while (and (characterp digit) (ascii-json-digit-p digit))
                       do (take)))
               (when (and (characterp (peek))
                          (member (peek) (list #\e #\E)))
                 (take)
                 (when (and (characterp (peek))
                            (member (peek) (list #\+ #\-)))
                   (take))
                 (loop for digit = (peek)
                       while (and (characterp digit) (ascii-json-digit-p digit))
                       do (take))))
             (run ()
               (unless (streamp stream)
                 (fail "input character stream"))
               (unless (input-stream-p stream)
                 (fail "input character stream"))
               (multiple-value-bind (character-stream-p certain-p)
                   (subtypep (stream-element-type stream) (quote character))
                 (unless (and certain-p character-stream-p)
                   (fail "input character stream")))
               (unless (and (integerp max-input-length) (not (minusp max-input-length)))
                 (fail "non-negative integer MAX-INPUT-LENGTH"))
               (loop for character = (peek)
                     while (and (characterp character) (whitespace-char-p character))
                     do (take))
               (let ((first (peek)))
                 (cond
                   ((eq first eof))
                   ((char= first #\") (take-string))
                   ((member first (list #\{ #\[)) (take-container))
                   ((char= first #\t) (take-count 4))
                   ((char= first #\f) (take-count 5))
                   ((char= first #\n) (take-count 4))
                   ((or (char= first #\-) (ascii-json-digit-p first)) (take-number))
                   (t (take))))
               (progn (let ((next (peek))) (unless (or (eq next eof) (and (characterp next) (whitespace-char-p next))) (fail "JSON whitespace or end of input after value"))) (let ((parse-options (copy-list options))) (remf parse-options :timeout-seconds) (apply (function parse) (coerce buffer (quote string)) parse-options)))))
      (progn (validate-timeout-seconds timeout-seconds (getf options :context "json") "") (if timeout-seconds #+sbcl (sb-ext:with-timeout timeout-seconds (run)) #-sbcl (run) (run))))))

(progn
  (defun parser-option-error (string position context expected)
    (multiple-value-bind (line column)
        (parse-error-location string position)
      (error 'json-parse-error
             :position position :line line :column column :path nil
             :expected expected :context context
             :text (safe-diagnostic-snippet string))))
  (defun resolve-parser-callback (callback name string position context)
    (cond
      ((null callback) nil)
      ((functionp callback) callback)
      ((and (symbolp callback) (fboundp callback)) (symbol-function callback))
      (t (parser-option-error string position context
                              (format nil "~A function designator" name)))))
  (defun %parse-prefix (string index
    &key
      (object-type :hash-table) (array-type :vector) (key-type :string)
      (duplicate-key-policy :last)
      (null-value +json-null+) (false-value +json-false+) (true-value t)
      key-decoder number-decoder object-hook array-hook
      (max-depth 512) (max-input-length 16777216)
      (max-string-length 1048576) (max-number-length 1024)
      (max-exact-exponent 10000) (max-array-elements 1000000)
      (max-object-members 1000000) (context "json") timeout-seconds)
    "Parse one JSON value at INDEX and return the value and its exclusive end index."
    (check-type string string)
    (let ((length (length string)))
      (unless (and (integerp index) (<= 0 index length))
        (parser-option-error string
                             (if (integerp index) (min length (max 0 index)) 0)
                             context "INDEX between zero and the input length"))
      (unless (member object-type (list :hash-table :alist))
        (parser-option-error string index context "OBJECT-TYPE :HASH-TABLE or :ALIST"))
      (unless (member array-type (list :vector :list))
        (parser-option-error string index context "ARRAY-TYPE :VECTOR or :LIST"))
      (unless (eq key-type :string) (parser-option-error string index context "KEY-TYPE :STRING"))
      (unless (member duplicate-key-policy (list :error :first :last :preserve))
        (parser-option-error string index context "DUPLICATE-KEY-POLICY :ERROR, :FIRST, :LAST, or :PRESERVE"))
      (when (and (eq duplicate-key-policy :preserve) (not (eq object-type :alist)))
        (parser-option-error string index context "OBJECT-TYPE :ALIST with DUPLICATE-KEY-POLICY :PRESERVE"))
      (dolist (limit (list max-depth max-input-length max-string-length
                           max-number-length max-exact-exponent
                           max-array-elements max-object-members))
        (unless (and (integerp limit) (not (minusp limit)))
          (parser-option-error string index context "non-negative integer resource limits")))
      (when (> length max-input-length)
        (parser-option-error string max-input-length context
                             "input within MAX-INPUT-LENGTH"))
      (validate-timeout-seconds timeout-seconds context string)
      (let ((resolved-key-decoder
              (resolve-parser-callback key-decoder "KEY-DECODER" string index context))
            (resolved-number-decoder
              (resolve-parser-callback number-decoder "NUMBER-DECODER" string index context))
            (resolved-object-hook
              (resolve-parser-callback object-hook "OBJECT-HOOK" string index context))
            (resolved-array-hook
              (resolve-parser-callback array-hook "ARRAY-HOOK" string index context)))
        (flet ((run ()
                 (let ((state
                         (make-parser-state
                           :text (coerce string 'simple-string) :length length :pos index
                           :object-type object-type :array-type array-type
                           :key-type key-type :duplicate-key-policy duplicate-key-policy
                           :null-value null-value :false-value false-value :true-value true-value
                           :key-decoder resolved-key-decoder
                           :number-decoder resolved-number-decoder
                           :object-hook resolved-object-hook :array-hook resolved-array-hook
                           :max-depth max-depth :max-string-length max-string-length
                           :max-number-length max-number-length
                           :max-exact-exponent max-exact-exponent
                           :max-array-elements max-array-elements
                           :max-object-members max-object-members :context context)))
                   (let ((value (parse-value state)))
                     (values value (ps-pos state))))))
          (if timeout-seconds
              #+sbcl (sb-ext:with-timeout timeout-seconds (run))
              #-sbcl (run)
              (run))))))
  (defun parse (string
      &key
      (object-type :hash-table) (array-type :vector) (key-type :string)
      (duplicate-key-policy :last)
      (null-value +json-null+) (false-value +json-false+) (true-value t)
      key-decoder number-decoder object-hook array-hook
      (max-depth 512) (max-input-length 16777216)
      (max-string-length 1048576) (max-number-length 1024)
      (max-exact-exponent 10000) (max-array-elements 1000000)
      (max-object-members 1000000) (context "json") timeout-seconds)
    "Parse STRING as one complete JSON text."
    (multiple-value-bind (value end-index)
        (parse-prefix string 0
                      :object-type object-type :array-type array-type :key-type key-type
                      :duplicate-key-policy duplicate-key-policy
                      :null-value null-value :false-value false-value :true-value true-value
                      :key-decoder key-decoder :number-decoder number-decoder
                      :object-hook object-hook :array-hook array-hook
                      :max-depth max-depth :max-input-length max-input-length
                      :max-string-length max-string-length :max-number-length max-number-length
                      :max-exact-exponent max-exact-exponent
                      :max-array-elements max-array-elements
                      :max-object-members max-object-members
                      :context context :timeout-seconds timeout-seconds)
      (let ((position end-index) (length (length string)))
        (loop while (and (< position length)
                         (whitespace-char-p (char string position)))
              do (incf position))
        (unless (= position length)
          (parser-option-error string position context "end of input"))
        value)))
  (defun parse-prefix (string &rest arguments)
  "Parse one JSON value from STRING and return its exclusive end position."
  (let ((index 0)
        (positional-index-p nil)
        (allowed-keys
          (list :object-type :array-type :key-type :duplicate-key-policy
                :null-value :false-value :true-value
                :key-decoder :number-decoder :object-hook :array-hook
                :max-depth :max-input-length :max-string-length
                :max-number-length :max-exact-exponent
                :max-array-elements :max-object-members
                :context :timeout-seconds)))
    (when (and arguments (not (keywordp (first arguments))))
      (setf index (pop arguments)
            positional-index-p t))
    (when (oddp (length arguments))
      (parser-option-error string 0 :options "keyword arguments in key/value pairs"))
    (loop for tail on arguments by (function cddr)
          for key = (first tail)
          unless (and (keywordp key)
                      (or (eq key :index) (member key allowed-keys)))
            do (parser-option-error string 0 :options
                                    "known PARSE-PREFIX keyword"))
    (let ((index-count (count :index arguments)))
      (when (> index-count 1)
        (parser-option-error string 0 :options "at most one :INDEX argument"))
      (when (= index-count 1)
        (when positional-index-p
          (parser-option-error string 0 :options
                               "either positional index or :INDEX, not both"))
        (setf index (getf arguments :index)
              arguments (loop for (key value) on arguments by (function cddr)
                              unless (eq key :index)
                                append (list key value)))))
    (apply (function %parse-prefix) string index arguments)))
)
