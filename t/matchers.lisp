;;;; t/matchers.lisp
;;;;
;;;; Domain-specific expectations and generators shared by every spec file, so
;;;; the specs read in the vocabulary of the library ("parses as", "stringifies
;;;; as", "round-trips") instead of raw predicate soup.
(in-package #:cl-json-kit/test)

(defmatcher :to-parse-as (actual expected)
  "Passes when the JSON text ACTUAL parses to a value EQUALP to the single
EXPECTED operand."
  (let ((expected-value (first expected))
        (parsed (parse actual)))
    (values (equalp parsed expected-value)
            (list :parsed parsed)
            (list :expected expected-value))))

(defmatcher :to-stringify-as (actual expected)
  "Passes when the Lisp value ACTUAL serializes to the single EXPECTED string."
  (let ((expected-value (first expected))
        (rendered (stringify actual)))
    (values (and (stringp expected-value) (string= rendered expected-value))
            (list :rendered rendered)
            (list :expected expected-value))))

(defmatcher :to-round-trip (actual expected)
  "Passes when ACTUAL survives STRINGIFY then PARSE unchanged (EQUALP)."
  (declare (ignore expected))
  (let ((restored (parse (stringify actual))))
    (values (equalp restored actual)
            (list :restored restored)
            (list :original actual))))

;;; A stress alphabet exercising every string-escape branch: quote, backslash,
;;; solidus, the short escapes (tab, newline, return, backspace, page), a
;;; below-0x20 control that has no short escape, and ordinary letters.
(defparameter +escape-stress-alphabet+
  (coerce (list #\" #\\ #\/ #\Tab #\Newline #\Return #\Backspace #\Page
                (code-char 1) #\a #\b #\z #\SPACE)
          'string))

;;; JSON's own punctuation and token vocabulary, so a fuzzer drawing from this
;;; alphabet has a real chance of assembling near-valid structure -- braces,
;;; digits, literal prefixes -- instead of only ever producing plain prose
;;; that PARSE rejects in the first two characters.
(defparameter +json-syntax-alphabet+
  (coerce (list #\{ #\} #\[ #\] #\: #\, #\" #\\ #\- #\. #\0 #\1 #\9
                #\t #\r #\u #\e #\f #\a #\l #\s #\n
                #\Tab #\Newline #\Space (code-char 1))
          'string))

(defun gen-json-string (&key (max-length 24))
  (gen-string :alphabet +escape-stress-alphabet+ :max-length max-length))

(defun gen-json-integer ()
  (gen-integer :min -1000000 :max 1000000))

;;; A named number decoder, used to prove fbound symbols work as callback
;;; designators (not only anonymous functions).
(defun symbol-number-decoder (token integer-p)
  (declare (ignore integer-p))
  (concatenate 'string "number:" token))

;;; The writer-side counterpart, proving :NUMBER-ENCODER also accepts an
;;; fbound symbol designator, not only an anonymous function.
(defun symbol-number-encoder (value)
  (declare (ignore value))
  "42")

(defmacro capture-json-parse-error (form)
  "Evaluate FORM and return the JSON-PARSE-ERROR condition it signals.
Signals a plain error if FORM returns normally instead of signalling one, so a
broken expectation fails loudly rather than silently comparing against NIL."
  `(handler-case (progn ,form (error "expected a JSON-PARSE-ERROR, but none was signalled"))
     (json-parse-error (condition) condition)))
