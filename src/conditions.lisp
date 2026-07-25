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
;;; Parse errors
;;; ---------------------------------------------------------------------
(define-condition json-parse-error (error)
  ((position :initarg :position :reader json-parse-error-position)
   (line :initarg :line :initform 1 :reader json-parse-error-line)
   (column :initarg :column :initform 1 :reader json-parse-error-column)
   (path :initarg :path :initform nil :reader json-parse-error-path)
   (expected :initarg :expected :initform nil :reader json-parse-error-expected)
   (context :initarg :context :initform "JSON" :reader json-parse-error-context)
   (text :initarg :text :initform ""))
  (:report
   (lambda (condition stream)
     (format stream "~A parse error at line ~D, column ~D (position ~D)~@[ at ~S~]~@[: expected ~A~]"
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

;;; ---------------------------------------------------------------------
;;; Serialization errors
;;; ---------------------------------------------------------------------
(define-condition json-serialization-error (error)
  ((message :initarg :message :initform "JSON serialization failed"
            :reader json-serialization-error-message)
   (path :initarg :path :initform nil :reader json-serialization-error-path))
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
