;;;; src/reader-strings.lisp
;;;;
;;;; Literal tokens (true/false/null) and JSON strings.  String decoding has a
;;;; zero-copy fast path (return a substring when nothing needs unescaping) and
;;;; a slow path that builds the result only once an escape or control
;;;; character is seen.  UTF-16 surrogate pairs in \uXXXX escapes decode to a
;;;; single Lisp character.
(in-package #:json-kit)

(defun parse-literal (state token value)
  "Match the fixed TOKEN (\"true\"/\"false\"/\"null\") at the cursor and return
VALUE, or signal a parse error."
  (let* ((start (ps-pos state))
         (end (+ start (length token))))
    (when (or (> end (ps-length state))
              (string/= (ps-text state) token :start1 start :end1 end))
      (parse-error-here state token))
    (setf (ps-pos state) end)
    value))

;;; ---------------------------------------------------------------------
;;; Unicode escapes
;;; ---------------------------------------------------------------------
(defun parse-hex4 (state)
  "Read exactly four hex digits at the cursor, returning their value and
advancing past them.  Works directly on the backing string with FIXNUM
arithmetic, so no per-digit character dispatch or generic multiply is needed."
  (let ((text (ps-text state))
        (length (ps-length state))
        (position (ps-pos state))
        (value 0))
    (declare (type simple-string text)
             (type fixnum length position value))
    (dotimes (index 4)
      (declare (ignore index))
      (when (>= position length)
        (setf (ps-pos state) position)
        (parse-error-here state))
      (let* ((code (char-code (schar text position)))
             (digit (cond
                      ((<= #x30 code #x39) (- code #x30))
                      ((<= #x41 code #x46) (+ 10 (- code #x41)))
                      ((<= #x61 code #x66) (+ 10 (- code #x61)))
                      (t nil))))
        (declare (type fixnum code) (type (or null fixnum) digit))
        (unless digit
          (setf (ps-pos state) position)
          (parse-error-here state))
        (setf value (logior (ash value 4) digit))
        (incf position)))
    (setf (ps-pos state) position)
    value))

(defun parse-unicode-escape (state)
  "Decode a \\uXXXX escape whose leading \\u the caller has consumed, combining
a high/low surrogate pair into one character and rejecting unpaired surrogates."
  (let ((code (parse-hex4 state)))
    (cond
      ((<= #xD800 code #xDBFF)
       ;; High surrogate: a low-surrogate escape must follow immediately.
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
       ;; Low surrogate with no preceding high surrogate.
       (parse-error-here state))
      (t (code-char code)))))

;;; ---------------------------------------------------------------------
;;; String bodies
;;; ---------------------------------------------------------------------
(defun parse-escaped-string-rest (state start)
  "Validate and size an escaped string, then decode it into one exact buffer."
  (let* ((text (ps-text state))
         (length (ps-length state))
         (position (ps-pos state))
         (decoded-length (- position start))
         (max-string-length (min (ps-max-string-length state) length)))
    (declare (type simple-string text)
             (type fixnum length position decoded-length max-string-length))
    (labels ((scan-ordinary-run ()
               (let ((run-start position))
                 (declare (type fixnum run-start))
                 (loop while (< position length)
                       for character = (schar text position)
                       for code fixnum = (char-code character)
                       while (and (char/= character #\")
                                  (char/= character #\\)
                                  (>= code #x20)
                                  (not (<= #xD800 code #xDFFF)))
                       do (incf position))
                 (let ((run-length (- position run-start)))
                   (declare (type fixnum run-length))
                   (when (> (+ decoded-length run-length) max-string-length)
                     (setf (ps-pos state)
                           (+ run-start (- max-string-length decoded-length) 1))
                     (parse-error-here state))
                   (incf decoded-length run-length))))
             (decode-validated-string (end final-position)
               (let ((result (make-string decoded-length
                                          :element-type (quote character)))
                     (source start)
                     (target 0))
                 (declare (type string result)
                          (type fixnum end final-position source target))
                 (loop while (< source end)
                       do (let ((character (schar text source)))
                            (if (char= character #\\)
                                (let* ((escape-position (1+ source))
                                       (letter (schar text escape-position))
                                       (decoded
                                         (if (char= letter #\u)
                                             (progn
                                               (setf (ps-pos state)
                                                     (1+ escape-position))
                                               (prog1 (parse-unicode-escape state)
                                                 (setf source (ps-pos state))))
                                             (prog1 (json-unescape-char letter)
                                               (setf source
                                                     (1+ escape-position))))))
                                  (setf (schar result target) decoded))
                                (progn
                                  (setf (schar result target) character)
                                  (incf source)))
                            (incf target)))
                 (setf (ps-pos state) final-position)
                 result)))
      (loop
        (scan-ordinary-run)
        (when (>= position length)
          (setf (ps-pos state) position)
          (parse-error-here state))
        (let* ((character (schar text position))
               (code (char-code character)))
          (declare (type fixnum code))
          (cond
            ((char= character #\")
             (let ((final-position (1+ position)))
               (setf (ps-pos state) final-position)
               (return (decode-validated-string position final-position))))
            ((char= character #\\)
             (let ((escape-position (1+ position)))
               (declare (type fixnum escape-position))
               (when (>= escape-position length)
                 (setf (ps-pos state) escape-position)
                 (parse-error-here state))
               (let* ((letter (schar text escape-position))
                      (decoded
                        (if (char= letter #\u)
                            (progn
                              (setf (ps-pos state) (1+ escape-position))
                              (prog1 (parse-unicode-escape state)
                                (setf position (ps-pos state))))
                            (prog1 (json-unescape-char letter)
                              (setf position (1+ escape-position))))))
                 (unless decoded
                   (setf (ps-pos state) escape-position)
                   (parse-error-here state))
                 (when (>= decoded-length max-string-length)
                   (setf (ps-pos state) position)
                   (parse-error-here state))
                 (incf decoded-length))))
            ((or (< code #x20) (<= #xD800 code #xDFFF))
             (setf (ps-pos state) position)
             (parse-error-here state))))))))

(defun parse-json-string (state)
  "Parse a JSON string, returning a zero-copy substring when the contents need
no unescaping and a freshly built string otherwise."
  (expect-char state #\")
  (let* ((text (ps-text state))
         (length (ps-length state))
         (position (ps-pos state))
         (start position)
         (max-string-length (ps-max-string-length state)))
    (declare (type simple-string text)
             (type fixnum length position start))
    (loop while (< position length)
          for character = (schar text position)
          for code fixnum = (char-code character)
          do (cond
               ((char= character #\")
                (setf (ps-pos state) (1+ position))
                (return-from parse-json-string
                  (subseq text start position)))
               ((or (char= character #\\) (< code #x20) (<= #xD800 code #xDFFF))
                (setf (ps-pos state) position)
                (return))
               (t
                (when (>= (- position start) max-string-length)
                  (setf (ps-pos state) position)
                  (parse-error-here state))
                (incf position))))
    (when (>= position length)
      (setf (ps-pos state) position)
      (parse-error-here state))
    (parse-escaped-string-rest state start)))
