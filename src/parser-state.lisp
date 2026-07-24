;;;; src/parser-state.lisp
;;;;
;;;; PARSER-STATE bundles the immutable configuration of one PARSE call with
;;;; the mutable scan cursor, and this file provides the primitive operations
;;;; over it: peeking, advancing, locating a source position, raising a located
;;;; error, and skipping whitespace.  Everything here is small and hot; the
;;;; grammar itself lives in the reader-* files.
(in-package #:json-kit)

;;; ---------------------------------------------------------------------
;;; Valid option vocabularies (data)
;;; ---------------------------------------------------------------------
;;; The accepted values for each shape option and the full set of PARSE-PREFIX
;;; keywords, named once so option validation is a membership test against data
;;; rather than logic with the vocabulary inlined at each check.
(defparameter +object-types+ '(:hash-table :alist))
(defparameter +array-types+ '(:vector :list))
(defparameter +duplicate-key-policies+ '(:error :first :last :preserve))

(defparameter +parse-keywords+
  '(:object-type :array-type :duplicate-key-policy
    :null-value :false-value :true-value
    :key-decoder :number-decoder :object-hook :array-hook
    :max-depth :max-input-length :max-string-length :max-number-length
    :max-exact-exponent :max-array-elements :max-object-members
    :context :timeout-seconds)
  "Every keyword PARSE accepts.")

(defparameter +parse-prefix-keywords+ (cons :index +parse-keywords+)
  "PARSE-PREFIX additionally accepts :INDEX to choose the start position.")

(defstruct (parser-state (:conc-name ps-))
  ;; Input and cursor.
  (text "" :type simple-string)
  (length 0 :type fixnum)
  (pos 0 :type fixnum)
  ;; Shape decisions, fixed for the whole parse.
  (object-type :hash-table)
  (array-type :vector)
  (duplicate-key-policy :last)
  ;; Scalar mappings.
  null-value false-value (true-value t)
  ;; User callbacks.
  key-decoder number-decoder object-hook array-hook
  ;; Error path and nesting.
  path
  (depth 0 :type fixnum)
  ;; Resource bounds.
  (max-depth 512 :type integer)
  (max-string-length 1048576 :type integer)
  (max-number-length 1024 :type integer)
  (max-exact-exponent 10000 :type integer)
  (max-array-elements 1000000 :type integer)
  (max-object-members 1000000 :type integer)
  (context "json"))

(declaim (inline ps-eof-p ps-peek ps-advance))

(defun ps-eof-p (state)
  (>= (ps-pos state) (ps-length state)))

(defun ps-peek (state &optional (offset 0))
  "The character OFFSET positions ahead of the cursor, or NIL past end of input."
  (let ((index (+ (ps-pos state) offset)))
    (when (< index (ps-length state))
      (char (ps-text state) index))))

(defun ps-advance (state)
  (incf (ps-pos state)))

(defun parse-error-location (text position)
  "The 1-based (LINE COLUMN) of POSITION in TEXT, counting CR, LF, and CRLF as
one line break each."
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
  "Signal a JSON-PARSE-ERROR at the cursor, tagged with the current path and,
optionally, what was EXPECTED."
  (multiple-value-bind (line column)
      (parse-error-location (ps-text state) (ps-pos state))
    (error 'json-parse-error
           :position (ps-pos state) :line line :column column
           :path (reverse (ps-path state)) :expected expected
           :context (ps-context state)
           :text (safe-diagnostic-snippet (ps-text state)))))

(defun whitespace-char-p (character)
  "True for the four characters RFC 8259 allows between tokens."
  (and character
       (member character '(#\Space #\Tab #\Newline #\Return #\Linefeed)
               :test #'char=)))

(defun skip-whitespace (state)
  (loop while (whitespace-char-p (ps-peek state))
        do (ps-advance state)))

(defun expect-char (state expected)
  "Consume EXPECTED at the cursor or signal a parse error there."
  (unless (eql (ps-peek state) expected)
    (parse-error-here state))
  (ps-advance state))
