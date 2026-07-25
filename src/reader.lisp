;;;; src/reader.lisp
;;;;
;;;; The string reading API: PARSE (one complete JSON text) and PARSE-PREFIX
;;;; (one value plus its exclusive end index).  All option validation happens
;;;; here, before any character of untrusted input is interpreted, and every
;;;; bad option is reported as a JSON-PARSE-ERROR rather than a Lisp error.
;;;; Stream framing (READ-JSON) builds on this and lives in reader-stream.lisp.
(in-package #:json-kit)

(defun validate-timeout-seconds (timeout-seconds context text)
  "Signal a parse error unless TIMEOUT-SECONDS is NIL or a non-negative real."
  (unless (or (null timeout-seconds)
              (and (realp timeout-seconds) (not (minusp timeout-seconds))))
    (error 'json-parse-error :position 0 :line 1 :column 1 :path nil
           :expected "TIMEOUT-SECONDS to be NIL or a non-negative real"
           :context context :text (safe-diagnostic-snippet text))))

;;; ---------------------------------------------------------------------
;;; Option plumbing
;;; ---------------------------------------------------------------------
(defun parser-option-error (string position context expected)
  "Report a bad PARSE/PARSE-PREFIX option as a located JSON-PARSE-ERROR."
  (multiple-value-bind (line column) (parse-error-location string position)
    (error 'json-parse-error
           :position position :line line :column column :path nil
           :expected expected :context context
           :text (safe-diagnostic-snippet string))))

(defun resolve-parser-callback (callback name string position context)
  "Coerce a callback designator (NIL, a function, or an fbound symbol) into a
function, or report a bad designator as a parse error."
  (resolve-callback-designator callback
    (parser-option-error string position context
                         (format nil "~A function designator" name))))

(defun %parse-prefix (string index
                      &key
                        (object-type :hash-table) (array-type :vector)
                        (duplicate-key-policy :last)
                        (null-value +json-null+) (false-value +json-false+)
                        (true-value t)
                        key-decoder number-decoder object-hook array-hook
                        (max-depth 512) (max-input-length 16777216)
                        (max-string-length 1048576) (max-number-length 1024)
                        (max-exact-exponent 10000) (max-array-elements 1000000)
                        (max-object-members 1000000) (context "json") timeout-seconds)
  "Parse one JSON value at INDEX and return the value and its exclusive end
index.  Validates every option before touching the input."
  (check-type string string)
  (let ((length (length string)))
    (macrolet ((require-option (test expected)
                 ;; Signal a located option error unless TEST holds; STRING,
                 ;; INDEX and CONTEXT come from the enclosing %PARSE-PREFIX.
                 `(unless ,test (parser-option-error string index context ,expected))))
      (unless (and (integerp index) (<= 0 index length))
        (parser-option-error string
                             (if (integerp index) (min length (max 0 index)) 0)
                             context "INDEX between zero and the input length"))
      (require-option (member object-type +object-types+)
                      "OBJECT-TYPE :HASH-TABLE or :ALIST")
      (require-option (member array-type +array-types+)
                      "ARRAY-TYPE :VECTOR or :LIST")
      (require-option (member duplicate-key-policy +duplicate-key-policies+)
                      "DUPLICATE-KEY-POLICY :ERROR, :FIRST, :LAST, or :PRESERVE")
      (require-option (or (not (eq duplicate-key-policy :preserve))
                          (eq object-type :alist))
                      "OBJECT-TYPE :ALIST with DUPLICATE-KEY-POLICY :PRESERVE")
      (dolist (limit (list max-depth max-input-length max-string-length
                           max-number-length max-exact-exponent
                           max-array-elements max-object-members))
        (require-option (and (integerp limit) (not (minusp limit)))
                        "non-negative integer resource limits")))
    (when (> length max-input-length)
      (parser-option-error string max-input-length context "input within MAX-INPUT-LENGTH"))
    (validate-timeout-seconds timeout-seconds context string)
    (let ((state
            (make-parser-state
             :text (coerce string 'simple-string) :length length :pos index
             :object-type object-type :array-type array-type
             :duplicate-key-policy duplicate-key-policy
             :null-value null-value :false-value false-value :true-value true-value
             :key-decoder (resolve-parser-callback key-decoder "KEY-DECODER"
                                                   string index context)
             :number-decoder (resolve-parser-callback number-decoder "NUMBER-DECODER"
                                                      string index context)
             :object-hook (resolve-parser-callback object-hook "OBJECT-HOOK"
                                                   string index context)
             :array-hook (resolve-parser-callback array-hook "ARRAY-HOOK"
                                                  string index context)
             :max-depth max-depth :max-string-length max-string-length
             :max-number-length max-number-length
             :max-exact-exponent max-exact-exponent
             :max-array-elements max-array-elements
             :max-object-members max-object-members :context context)))
      (with-optional-timeout (timeout-seconds)
        (let ((value (parse-value state)))
          (values value (ps-pos state)))))))

(defun parse (string
              &key
                (object-type :hash-table) (array-type :vector)
                (duplicate-key-policy :last)
                (null-value +json-null+) (false-value +json-false+) (true-value t)
                key-decoder number-decoder object-hook array-hook
                (max-depth 512) (max-input-length 16777216)
                (max-string-length 1048576) (max-number-length 1024)
                (max-exact-exponent 10000) (max-array-elements 1000000)
                (max-object-members 1000000) (context "json") timeout-seconds)
  "Parse STRING as exactly one complete JSON text, rejecting trailing data."
  (multiple-value-bind (value end-index)
      (call-with-forwarded-parse-keywords #'%parse-prefix string 0)
    (let ((position end-index)
          (length (length string)))
      (loop while (and (< position length)
                       (whitespace-char-p (char string position)))
            do (incf position))
      (unless (= position length)
        (parser-option-error string position context "end of input"))
      value)))

(defun parse-prefix (string &rest arguments)
  "Parse one JSON value from STRING and return it plus its exclusive end index.
The parse start defaults to zero; pass :INDEX to begin elsewhere.  All other
keywords match PARSE."
  (when (oddp (length arguments))
    (parser-option-error string 0 :options "keyword arguments in key/value pairs"))
  (loop for tail on arguments by #'cddr
        for key = (first tail)
        unless (and (keywordp key) (member key +parse-prefix-keywords+))
          do (parser-option-error string 0 :options "known PARSE-PREFIX keyword"))
  (when (> (count :index arguments) 1)
    (parser-option-error string 0 :options "at most one :INDEX argument"))
  (let ((index (getf arguments :index 0))
        (forwarded (loop for (key value) on arguments by #'cddr
                         unless (eq key :index)
                           append (list key value))))
    (apply #'%parse-prefix string index forwarded)))
