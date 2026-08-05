;;;; src/writer-strings.lisp
;;;;
;;;; Serializing JSON strings.  Runs of characters that need no escaping are
;;;; flushed with a single WRITE-STRING; only an escape or control character
;;;; interrupts the run.  Control characters escape via
;;;; EMIT-CONTROL-CHAR-ESCAPE, using the shared +JSON-SHORT-ESCAPES+ table for
;;;; the short letter forms and a \uXXXX numeric escape otherwise.
(in-package #:json-kit)

;;; ---------------------------------------------------------------------
;;; Strings
;;; ---------------------------------------------------------------------
(defun emit-control-char-escape (character code)
  "Emit CHARACTER (whose CODE is below #x20) as its JSON escape: the short
letter form (\\n, \\t, ...) when CHARACTER has one, otherwise a \\u00XX numeric
escape.  Shared by WRITE-JSON-STRING's buffered and run-flushing branches."
  (let ((letter (json-escape-letter character)))
    (if letter
        (progn (emit-character #\\) (emit-character letter))
        (progn
          (reserve-output 6)
          (write-string "\\u00" *json-output-stream*)
          (write-char (schar +hex-digits+ (ash code -4))
                      *json-output-stream*)
          (write-char (schar +hex-digits+ (logand code #x0f))
                      *json-output-stream*)))))

(defun write-json-string (string)
  "Serialize STRING as a quoted, escaped JSON string, rejecting raw surrogates.
Contiguous unescaped characters are flushed as a single WRITE-STRING run and
only an escape or control character interrupts the run, so an ordinary string
costs one write rather than one per character."
  (declare (type string string))
  (emit-character #\")
  (let ((size (length string)))
    (declare (type fixnum size))
    (if (and (null *json-maximum-output-length*)
             (>= size 128)
             (loop for index fixnum below 16
                   for character = (char string index)
                   thereis (or (char= character #\")
                               (char= character #\\)))
             (>= (loop for index fixnum below 128
                       for character = (char string index)
                       count (or (char= character #\")
                                 (char= character #\\)))
                 12))
        (let* ((buffer-size (if (< size 4096) (* size 2) 8192))
               (buffer (make-string buffer-size))
               (used 0))
          (declare (type fixnum buffer-size used)
                   (type simple-string buffer))
          (labels ((flush-buffer ()
                     (unless (zerop used)
                       (if (or (null *json-maximum-output-length*)
                               (<= used (- *json-maximum-output-length*
                                           *json-output-count*)))
                           (progn
                             (reserve-output used)
                             (write-string buffer *json-output-stream* :end used))
                           (loop for index fixnum below used
                                 do (emit-character (schar buffer index))))
                       (setf used 0))))
            (loop for index fixnum below size
                  for character = (char string index)
                  for code fixnum = (char-code character)
                  do (cond
                       ((< code #x20)
                        (flush-buffer)
                        (emit-control-char-escape character code))
                       ((char= character #\")
                        (when (> used (- buffer-size 2))
                          (flush-buffer))
                        (setf (schar buffer used) #\\
                              (schar buffer (1+ used)) #\")
                        (incf used 2))
                       ((char= character #\\)
                        (when (> used (- buffer-size 2))
                          (flush-buffer))
                        (setf (schar buffer used) #\\
                              (schar buffer (1+ used)) #\\)
                        (incf used 2))
                       ((<= #xd800 code #xdfff)
                        (flush-buffer)
                        (serialization-error
                         "JSON strings cannot contain raw surrogate characters"))
                       (t
                        (when (= used buffer-size)
                          (flush-buffer))
                        (setf (schar buffer used) character)
                        (incf used))))
            (flush-buffer)))
        (let ((run-start 0))
          (declare (type fixnum run-start))
          (labels ((flush-run (end)
                     (when (< run-start end)
                       (let ((length (- end run-start)))
                         (if (or (null *json-maximum-output-length*)
                                 (<= length (- *json-maximum-output-length*
                                               *json-output-count*)))
                             (progn
                               (reserve-output length)
                               (write-string string *json-output-stream*
                                             :start run-start :end end))
                             (loop for index from run-start below end
                                   do (emit-character (char string index))))))))
            (loop for index below size
                  for character = (char string index)
                  for code = (char-code character)
                  do (cond
                       ((< code #x20)
                        (flush-run index)
                        (emit-control-char-escape character code)
                        (setf run-start (1+ index)))
                       ((char= character #\") (flush-run index) (emit-string "\\\"")
                        (setf run-start (1+ index)))
                       ((char= character #\\) (flush-run index) (emit-string "\\\\")
                        (setf run-start (1+ index)))
                       ((<= #xd800 code #xdfff)
                        (flush-run index)
                        (serialization-error
                         "JSON strings cannot contain raw surrogate characters"))))
            (flush-run size)))))
  (emit-character #\"))
