;;;; src/conditions.lisp
;;;;
;;;; The structured conditions PARSE and the writer signal, plus the bounded
;;;; diagnostic helpers that keep an error report from itself becoming an
;;;; attack surface: every attacker-influenced string, path, or "expected"
;;;; value is truncated and escaped before it reaches a condition slot.
(in-package #:json-kit)

(defconstant +maximum-error-snippet-length+ 256)

;;; ---------------------------------------------------------------------
;;; Bounded, escaped diagnostic rendering
;;; ---------------------------------------------------------------------
(defun safe-diagnostic-snippet (value &optional (maximum-length +maximum-error-snippet-length+))
  "A bounded, control-character-escaped rendering of VALUE suitable for an
error message, never longer than MAXIMUM-LENGTH characters."
  (let ((source
          (cond
            ((stringp value) value)
            ((characterp value) (string value))
            ((symbolp value) (symbol-name value))
            ((and (integerp value)
                  (> (integer-length value) (* 4 maximum-length)))
             "<INTEGER>")
            ((numberp value)
             (let ((*print-readably* nil)
                   (*print-circle* t)
                   (*print-length* 8)
                   (*print-level* 4))
               (write-to-string value)))
            (t
             (format nil "<~A>" (safe-diagnostic-snippet (type-of value) 64))))))
    (with-output-to-string (output)
      (loop with written = 0
            for character across source
            for code = (char-code character)
            for escaped = (case code
                            (8 "\\b")
                            (9 "\\t")
                            (10 "\\n")
                            (12 "\\f")
                            (13 "\\r")
                            (otherwise
                             (cond
                               ((char= character #\\) "\\\\")
                               ((char= character #\") "\\\"")
                               ((or (< code 32) (= code 127))
                                (format nil "\\u~4,'0X" code))
                               (t (string character)))))
            while (<= (+ written (length escaped)) maximum-length)
            do (write-string escaped output)
               (incf written (length escaped))))))

(defun bounded-diagnostic-path (path &optional (maximum-elements 32))
  "A bounded copy of an error PATH: at most MAXIMUM-ELEMENTS components, each a
small nonnegative index or an escaped string, cycle-safe."
  (when path
    (if (listp path)
        (loop with seen = (make-hash-table :test #'eq)
              for tail = path then (cdr tail)
              for count below maximum-elements
              while (consp tail)
              until (gethash tail seen)
              do (setf (gethash tail seen) t)
              collect (let ((component (car tail)))
                        (cond
                          ((stringp component)
                           (safe-diagnostic-snippet component 64))
                          ((and (integerp component)
                                (<= 0 component most-positive-fixnum))
                           component)
                          (t (safe-diagnostic-snippet component 64)))))
        (list (safe-diagnostic-snippet path 64)))))

(defun bounded-expected-value (expected)
  "A bounded rendering of an error's EXPECTED description, or NIL."
  (when expected
    (safe-diagnostic-snippet expected 128)))

;;; ---------------------------------------------------------------------
;;; Base condition
;;; ---------------------------------------------------------------------
(define-condition json-kit-error (error)
  ()
  (:documentation
   "The base condition of every condition CL-JSON-KIT signals.  A caller that
wants to catch this package's whole failure surface in one HANDLER-CASE
clause should catch this type instead of ERROR: JSON-PARSE-ERROR and
JSON-SERIALIZATION-ERROR both derive from it, and any condition type this
library adds in the future will too."))

;;; ---------------------------------------------------------------------
;;; Parse errors
;;; ---------------------------------------------------------------------
(define-condition json-parse-error (json-kit-error)
  ((position :initarg :position :reader json-parse-error-position
             :documentation "Zero-based character index of the offending input.")
   (line :initarg :line :initform 1 :reader json-parse-error-line
         :documentation "One-based line number of the offending input.")
   (column :initarg :column :initform 1 :reader json-parse-error-column
           :documentation "One-based column number of the offending input.")
   (path :initarg :path :initform nil :reader json-parse-error-path
         :documentation "Bounded location within the value: object keys and array indices.")
   (expected :initarg :expected :initform nil :reader json-parse-error-expected
             :documentation "Bounded description of what the reader required instead.")
   (context :initarg :context :initform "JSON" :reader json-parse-error-context
            :documentation "Bounded caller-supplied label naming the input being parsed.")
   (text :initarg :text :initform ""
         :documentation "Bounded snippet of the input, read via JSON-PARSE-ERROR-TEXT."))
  (:documentation
   "Signalled for any input the reader refuses, and the only condition PARSE,
PARSE-PREFIX, and READ-JSON signal for malformed JSON.  Every slot that can
carry attacker-influenced data is truncated and control-character-escaped before
it is stored, so reporting the condition cannot itself become an attack surface.")
  (:report
   (lambda (condition stream)
     (format stream
             "~A parse error at line ~D, column ~D (position ~D)~@[ at ~S~]~@[: expected ~A~]"
             (json-parse-error-context condition)
             (json-parse-error-line condition)
             (json-parse-error-column condition)
             (json-parse-error-position condition)
             (json-parse-error-path condition)
             (json-parse-error-expected condition)))))

(defun bounded-json-parse-error (&key position line column path expected context text)
  "Construct a JSON-PARSE-ERROR with every attacker-influenced slot (PATH,
EXPECTED, CONTEXT, TEXT) bounded and escaped exactly once.  Common Lisp does
not guarantee that a condition class runs INITIALIZE-INSTANCE (SBCL's
DEFINE-CONDITION classes do not), so every JSON-PARSE-ERROR call site
constructs its condition here rather than relying on an :AFTER method that
would silently never run."
  (make-condition 'json-parse-error
                  :position position :line line :column column
                  :path (bounded-diagnostic-path path)
                  :expected (bounded-expected-value expected)
                  :context (safe-diagnostic-snippet context)
                  :text (safe-diagnostic-snippet text)))

(defun json-parse-error-text (condition)
  "The bounded snippet of the input text captured when CONDITION was signalled."
  (slot-value condition 'text))

;;; DEFINE-CONDITION generates the readers above but has nowhere to put a
;;; docstring on them, so they are attached here: the whole exported surface
;;; answers DOCUMENTATION at the REPL, not just the parts written as DEFUNs.
(loop for (name . text)
        in '((json-parse-error-position
              . "Zero-based character index in the input where parsing failed.")
             (json-parse-error-line
              . "One-based line number in the input where parsing failed.")
             (json-parse-error-column
              . "One-based column number in the input where parsing failed.")
             (json-parse-error-path
              . "Bounded path to the failure as a list of object keys (strings) and
array indices (integers), outermost first, or NIL at the top level.")
             (json-parse-error-expected
              . "Bounded description of what the reader required at the failure point,
or NIL when it has nothing more specific to report.")
             (json-parse-error-context
              . "Bounded label naming the input, from PARSE's :CONTEXT argument;
\"JSON\" when the caller supplied none."))
      do (setf (documentation name 'function) text))

;;; ---------------------------------------------------------------------
;;; Serialization errors
;;; ---------------------------------------------------------------------
(define-condition json-serialization-error (json-kit-error)
  ((message :initarg :message :initform "JSON serialization failed"
            :reader json-serialization-error-message
            :documentation "Bounded description of why serialization failed.")
   (path :initarg :path :initform nil :reader json-serialization-error-path
         :documentation "Bounded location of the offending value within the input value."))
  (:documentation
   "Signalled for any value the writer refuses, and the only condition STRINGIFY
and WRITE-JSON signal: a value of an unsupported type, a non-finite float, a
ratio with no terminating decimal expansion, a raw surrogate character, a
circular structure, or output exceeding a configured bound.  Both slots are
truncated and escaped before they are stored.")
  (:report
   (lambda (condition stream)
     (let ((message (json-serialization-error-message condition))
           (path (json-serialization-error-path condition)))
       (if path
           (format stream "JSON serialization error at ~S: ~A" path message)
           (format stream "JSON serialization error: ~A" message))))))

(defun bounded-json-serialization-error (&key message path)
  "Construct a JSON-SERIALIZATION-ERROR with MESSAGE and PATH bounded and
escaped exactly once -- see BOUNDED-JSON-PARSE-ERROR for why this cannot be an
INITIALIZE-INSTANCE :AFTER method."
  (make-condition 'json-serialization-error
                  :message (safe-diagnostic-snippet message)
                  :path (bounded-diagnostic-path path)))

(loop for (name . text)
        in '((json-serialization-error-message
              . "Bounded description of why the value could not be serialized.")
             (json-serialization-error-path
              . "Bounded path to the offending value as a list of object keys (strings)
and array indices (integers), outermost first, or NIL at the top level."))
      do (setf (documentation name 'function) text))
