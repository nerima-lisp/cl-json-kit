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

(defstruct (parser-state (:conc-name ps-))
  (text "" :type simple-string)
  (length 0 :type fixnum)
  (pos 0 :type fixnum)
  (object-type :hash-table)
  (array-type :vector)
  (key-type :keyword)
  (context "json"))

(declaim (inline ps-eof-p ps-peek ps-advance))

(defun ps-eof-p (state)
  (>= (ps-pos state) (ps-length state)))

(defun ps-peek (state &optional (offset 0))
  (let ((index (+ (ps-pos state) offset)))
    (when (< index (ps-length state))
      (char (ps-text state) index))))

(defun ps-advance (state)
  (incf (ps-pos state)))

(defun parse-error-here (state)
  (error 'json-parse-error
         :position (ps-pos state)
         :context (ps-context state)
         :text (ps-text state)))

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
    (unless c
      (parse-error-here state))
    (cond
      ((char= c #\") (parse-json-string state))
      ((char= c #\{) (parse-object state))
      ((char= c #\[) (parse-array state))
      ((or (digit-char-p c) (char= c #\-)) (parse-number state))
      ((char= c #\t) (parse-literal state "true" t))
      ((char= c #\f) (parse-literal state "false" :false))
      ((char= c #\n) (parse-literal state "null" :null))
      (t (parse-error-here state)))))

(defun parse-literal (state token value)
  (let* ((start (ps-pos state))
         (end (+ start (length token))))
    (when (or (> end (ps-length state))
              (string/= (ps-text state) token :start1 start :end1 end))
      (parse-error-here state))
    (setf (ps-pos state) end)
    value))

;;; ---------------------------------------------------------------------
;;; Strings
;;; ---------------------------------------------------------------------

(defun hex-digit-value (c)
  (or (digit-char-p c 16)
      nil))

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
  "Assumes the current character is the opening double quote.  Returns the
decoded Lisp string (the caller decides what to do with it: an object key or
a JSON string value)."
  (expect-char state #\")
  (with-output-to-string (out)
    (loop
      (when (ps-eof-p state)
        (parse-error-here state))
      (let ((c (ps-peek state)))
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
               (#\" (write-char #\" out) (ps-advance state))
               (#\\ (write-char #\\ out) (ps-advance state))
               (#\/ (write-char #\/ out) (ps-advance state))
               (#\b (write-char #\Backspace out) (ps-advance state))
               (#\f (write-char #\Page out) (ps-advance state))
               (#\n (write-char #\Newline out) (ps-advance state))
               (#\r (write-char #\Return out) (ps-advance state))
               (#\t (write-char #\Tab out) (ps-advance state))
               (#\u (ps-advance state) (write-char (parse-unicode-escape state) out))
               (t (parse-error-here state)))))
          ((< (char-code c) #x20)
           (parse-error-here state))
          (t (write-char c out) (ps-advance state)))))))

;;; ---------------------------------------------------------------------
;;; Numbers
;;; ---------------------------------------------------------------------

(defun consume-digits (state)
  "Advance past a (possibly empty) run of decimal digits and return how many
were consumed."
  (let ((start (ps-pos state)))
    (loop while (and (ps-peek state) (digit-char-p (ps-peek state)))
          do (ps-advance state))
    (- (ps-pos state) start)))

(defun require-at-least-one-digit (state)
  (when (zerop (consume-digits state))
    (parse-error-here state)))

(defun parse-number (state)
  (let ((start (ps-pos state)))
    (when (eql (ps-peek state) #\-)
      (ps-advance state))
    (unless (and (ps-peek state) (digit-char-p (ps-peek state)))
      (parse-error-here state))
    (if (eql (ps-peek state) #\0)
        (ps-advance state)
        (require-at-least-one-digit state))
    (when (eql (ps-peek state) #\.)
      (ps-advance state)
      (require-at-least-one-digit state))
    (when (member (ps-peek state) '(#\e #\E))
      (ps-advance state)
      (when (member (ps-peek state) '(#\+ #\-))
        (ps-advance state))
      (require-at-least-one-digit state))
    (let ((token (subseq (ps-text state) start (ps-pos state)))
          (*read-default-float-format* 'double-float))
      (handler-case (values (read-from-string token))
        (error () (parse-error-here state))))))

;;; ---------------------------------------------------------------------
;;; Objects and arrays
;;; ---------------------------------------------------------------------

(defun json-key->lisp-key (key-string key-type)
  (ecase key-type
    (:string key-string)
    (:keyword (intern (string-upcase key-string) :keyword))))

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
  (expect-char state #\{)
  (skip-whitespace state)
  (let ((pairs '()))
    (if (eql (ps-peek state) #\})
        (ps-advance state)
        (loop
          (skip-whitespace state)
          (unless (eql (ps-peek state) #\")
            (parse-error-here state))
          (let ((key (parse-json-string state)))
            (skip-whitespace state)
            (expect-char state #\:)
            (skip-whitespace state)
            (let ((value (parse-value state)))
              (push (cons (json-key->lisp-key key (ps-key-type state)) value) pairs)))
          (skip-whitespace state)
          (let ((c (ps-peek state)))
            (cond
              ((eql c #\,)
               (ps-advance state)
               (skip-whitespace state)
               (when (eql (ps-peek state) #\})
                 ;; Trailing comma before the closing brace.
                 (parse-error-here state)))
              ((eql c #\})
               (ps-advance state)
               (return))
              (t (parse-error-here state))))))
    (assemble-object (nreverse pairs) (ps-object-type state))))

(defun parse-array (state)
  (expect-char state #\[)
  (skip-whitespace state)
  (let ((elements '()))
    (if (eql (ps-peek state) #\])
        (ps-advance state)
        (loop
          (skip-whitespace state)
          (push (parse-value state) elements)
          (skip-whitespace state)
          (let ((c (ps-peek state)))
            (cond
              ((eql c #\,)
               (ps-advance state)
               (skip-whitespace state)
               (when (eql (ps-peek state) #\])
                 ;; Trailing comma before the closing bracket.
                 (parse-error-here state)))
              ((eql c #\])
               (ps-advance state)
               (return))
              (t (parse-error-here state))))))
    (assemble-array (nreverse elements) (ps-array-type state))))

;;; ---------------------------------------------------------------------
;;; Public entry point
;;; ---------------------------------------------------------------------

(defun parse (string &key (object-type :hash-table)
                        (array-type :vector)
                        (key-type :keyword)
                        (context "json")
                        timeout-seconds)
  "Parse STRING as JSON.

OBJECT-TYPE is :HASH-TABLE (default) or :ALIST: each JSON object is built as
a HASH-TABLE (test #'EQUAL) or as an ALIST, respectively.  ARRAY-TYPE is
:VECTOR (default) or :LIST: each JSON array is built as a SIMPLE-VECTOR or a
LIST.  KEY-TYPE is :KEYWORD (default) or :STRING: object keys are interned as
upcased keywords, or kept as raw strings.

The type of every object/array is fixed the moment its closing brace/bracket
is read; nothing here re-inspects already-built Lisp values to guess their
intended JSON shape.

TIMEOUT-SECONDS, if given, bounds the whole parse with SB-EXT:WITH-TIMEOUT
and signals SB-EXT:TIMEOUT if exceeded.

Malformed input (unterminated strings, trailing commas, lone surrogates,
etc.) signals JSON-PARSE-ERROR with the offending POSITION and the CONTEXT
string (defaults to \"json\"; pass e.g. a file name for better diagnostics
downstream).

\\uXXXX escapes are decoded as UTF-16, so a high surrogate (U+D800-U+DBFF)
immediately followed by a low surrogate (U+DC00-U+DFFF) escape combines into
a single character outside the Basic Multilingual Plane (e.g. emoji)."
  (check-type string string)
  (flet ((run ()
           (let ((state (make-parser-state :text (coerce string 'simple-string)
                                            :length (length string)
                                            :pos 0
                                            :object-type object-type
                                            :array-type array-type
                                            :key-type key-type
                                            :context context)))
             (let ((value (parse-value state)))
               (skip-whitespace state)
               (unless (ps-eof-p state)
                 (parse-error-here state))
               value))))
    (if timeout-seconds
        (sb-ext:with-timeout timeout-seconds (run))
        (run))))
