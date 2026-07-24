;;;; src/reader-stream.lisp
;;;;
;;;; Framing exactly one JSON value out of a character stream.  READ-JSON scans
;;;; just enough characters to bound one value -- a string, a balanced
;;;; container, a literal, or a number -- without consuming the following value
;;;; or trailing whitespace, then hands the buffered text to PARSE.  This is a
;;;; separate concern from string parsing, so it lives in its own file.
(in-package #:json-kit)

;;; ---------------------------------------------------------------------
;;; Stream framing
;;; ---------------------------------------------------------------------
(defun read-json (stream &rest options &key (max-input-length 16777216) &allow-other-keys)
  "Read exactly one JSON value from STREAM, consuming its characters but not the
following value or trailing whitespace.  The value is buffered and handed to
PARSE, so every PARSE keyword is accepted here too."
  (let ((buffer (make-array 0 :element-type 'character :adjustable t :fill-pointer 0))
        (eof (gensym "EOF"))
        (timeout-seconds (getf options :timeout-seconds)))
    (labels ((fail (expected)
               (let ((text (coerce buffer 'string)))
                 (multiple-value-bind (line column)
                     (parse-error-location text (length text))
                   (error 'json-parse-error :position (length text) :line line :column column
                          :path nil :expected expected :context "stream"
                          :text (safe-diagnostic-snippet text)))))
             (peek () (peek-char nil stream nil eof))
             (take ()
               (when (>= (length buffer) max-input-length)
                 (fail "input within MAX-INPUT-LENGTH"))
               (vector-push-extend (read-char stream) buffer))
             (take-count (count)
               (loop repeat count until (eq (peek) eof) do (take)))
             (take-string ()
               (take)                   ; opening quote
               (let ((escaped nil))
                 (loop for character = (peek)
                       until (eq character eof)
                       do (take)
                          (cond
                            (escaped (setf escaped nil))
                            ((char= character #\\) (setf escaped t))
                            ((char= character #\") (return))))))
             (take-container ()
               ;; Balance nested {}/[] without interpreting the contents,
               ;; ignoring brackets that occur inside strings.
               (let ((closers (list (if (char= (peek) #\{) #\} #\])))
                     (in-string nil)
                     (escaped nil))
                 (take)                 ; opening bracket
                 (loop for character = (peek)
                       while closers
                       until (eq character eof)
                       do (take)
                          (cond
                            (in-string
                             (cond
                               (escaped (setf escaped nil))
                               ((char= character #\\) (setf escaped t))
                               ((char= character #\") (setf in-string nil))))
                            ((char= character #\") (setf in-string t))
                            ((char= character #\{) (push #\} closers))
                            ((char= character #\[) (push #\] closers))
                            ((member character '(#\} #\]))
                             (if (char= character (first closers))
                                 (pop closers)
                                 (return)))))))
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
               (when (and (characterp (peek)) (member (peek) '(#\e #\E)))
                 (take)
                 (when (and (characterp (peek)) (member (peek) '(#\+ #\-)))
                   (take))
                 (loop for digit = (peek)
                       while (and (characterp digit) (ascii-json-digit-p digit))
                       do (take))))
             (run ()
               (unless (streamp stream) (fail "input character stream"))
               (unless (input-stream-p stream) (fail "input character stream"))
               (multiple-value-bind (character-stream-p certain-p)
                   (subtypep (stream-element-type stream) 'character)
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
                   ((member first '(#\{ #\[)) (take-container))
                   ((char= first #\t) (take-count 4))
                   ((char= first #\f) (take-count 5))
                   ((char= first #\n) (take-count 4))
                   ((or (char= first #\-) (ascii-json-digit-p first)) (take-number))
                   (t (take))))
               (let ((next (peek)))
                 (unless (or (eq next eof) (and (characterp next) (whitespace-char-p next)))
                   (fail "JSON whitespace or end of input after value")))
               (let ((parse-options (copy-list options)))
                 (remf parse-options :timeout-seconds)
                 (apply #'parse (coerce buffer 'string) parse-options))))
      (validate-timeout-seconds timeout-seconds (getf options :context "json") "")
      (with-optional-timeout (timeout-seconds) (run)))))
