;;;; src/writer-state.lisp
;;;;
;;;; The writer's dynamic configuration and its output primitives.  A single
;;;; WRITE-JSON call binds these specials once; every emit checks the running
;;;; output budget so a hostile or runaway value cannot produce unbounded text.
(in-package #:json-kit)

(defconstant +default-maximum-serialization-depth+ 512)
(defconstant +default-maximum-serialization-elements+ 1000000)
(defconstant +default-maximum-output-length+ 16777216)

(defvar *json-output-stream*)
(defvar *json-output-count*)
(defvar *json-maximum-output-length*)
(defvar *json-maximum-depth*)
(defvar *json-maximum-elements*)
(defvar *json-pretty*)
(defvar *json-indent*)
(defvar *json-sort-keys*)
(defvar *json-null-value*)
(defvar *json-false-value*)
(defvar *json-number-encoder*)
(defvar *json-active-aggregates*)
(defvar *json-serialization-path* nil)

(defun serialization-error (control &rest arguments)
  "Signal a JSON-SERIALIZATION-ERROR describing the current path and a message
built from CONTROL and ARGUMENTS."
  (error 'json-serialization-error
         :message (apply #'format nil control arguments)
         :path (reverse *json-serialization-path*)))

;;; ---------------------------------------------------------------------
;;; Option validation
;;; ---------------------------------------------------------------------
(defun valid-limit-p (value)
  "True when VALUE is an acceptable resource limit: NIL or a nonnegative integer."
  (or (null value) (and (integerp value) (not (minusp value)))))

(defun validate-writer-options (indent maximum-depth maximum-elements maximum-output-length)
  (unless (and (integerp indent) (not (minusp indent)))
    (serialization-error "INDENT must be a non-negative integer, not ~S" indent))
  (dolist (entry (list (cons "MAX-DEPTH" maximum-depth)
                       (cons "MAX-ELEMENTS" maximum-elements)
                       (cons "MAX-OUTPUT-LENGTH" maximum-output-length)))
    (unless (valid-limit-p (cdr entry))
      (serialization-error "~A must be NIL or a non-negative integer, not ~S"
                           (car entry) (cdr entry)))))

(defun resolve-number-encoder (designator)
  "Coerce a number-encoder DESIGNATOR (NIL, a function, or an fbound symbol)
into a function or NIL."
  (cond
    ((null designator) nil)
    ((functionp designator) designator)
    ((and (symbolp designator) (fboundp designator)) (symbol-function designator))
    (t (serialization-error "NUMBER-ENCODER must be a function designator"))))

;;; ---------------------------------------------------------------------
;;; Bounded output primitives
;;; ---------------------------------------------------------------------
(defun reserve-output (length)
  "Account for LENGTH characters of pending output, signalling before the
configured maximum is exceeded."
  (when (and *json-maximum-output-length*
             (> length (- *json-maximum-output-length* *json-output-count*)))
    (serialization-error "serialized output exceeds the configured maximum length"))
  (incf *json-output-count* length))

(defun emit-string (string)
  (let ((length (length string)))
    (reserve-output length)
    ;; For the very short strings the writer emits most often (two-character
    ;; escapes, small number tokens) a WRITE-CHAR loop beats the per-call
    ;; overhead of WRITE-STRING.
    (if (<= length 4)
        (loop for character across string
              do (write-char character *json-output-stream*))
        (write-string string *json-output-stream*))))

(defun emit-character (character)
  (reserve-output 1)
  (write-char character *json-output-stream*))

(defun emit-indent (level)
  "Emit a newline and LEVEL indentation steps for pretty output."
  (emit-character #\Newline)
  (let ((count (* *json-indent* level)))
    (reserve-output count)
    (dotimes (index count)
      (declare (ignore index))
      (write-char #\Space *json-output-stream*))))

(defun ensure-depth (level)
  (when (and *json-maximum-depth* (> level *json-maximum-depth*))
    (serialization-error "serialization nesting exceeds MAX-DEPTH")))

(defun ensure-element-count (count)
  (when (and *json-maximum-elements* (> count *json-maximum-elements*))
    (serialization-error "aggregate contains more than MAX-ELEMENTS elements")))
