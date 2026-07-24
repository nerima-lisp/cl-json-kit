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
(defun read-string-escape (state emit)
  "At a backslash, consume the escape sequence and call EMIT with its decoded
character."
  (ps-advance state)                    ; consume the backslash
  (when (ps-eof-p state) (parse-error-here state))
  (let ((letter (ps-peek state)))
    (if (char= letter #\u)
        (progn
          (ps-advance state)
          (funcall emit (parse-unicode-escape state)))
        (let ((character (json-unescape-char letter)))
          (unless character (parse-error-here state))
          (ps-advance state)
          (funcall emit character)))))

(defun parse-escaped-string-rest (state start)
  "Build the decoded string from the already-scanned ordinary run
[START, cursor) onward, through escapes, to the closing quote."
  (let ((decoded-length (- (ps-pos state) start)))
    (with-output-to-string (out)
      (write-string (ps-text state) out :start start :end (ps-pos state))
      (flet ((emit (character)
               (when (>= decoded-length (ps-max-string-length state))
                 (parse-error-here state))
               (incf decoded-length)
               (write-char character out)))
        (loop
          (when (ps-eof-p state) (parse-error-here state))
          (let* ((character (ps-peek state))
                 (code (char-code character)))
            (cond
              ((char= character #\") (ps-advance state) (return))
              ((char= character #\\) (read-string-escape state #'emit))
              ((or (< code #x20) (<= #xD800 code #xDFFF))
               (parse-error-here state))
              (t (ps-advance state) (emit character)))))))))

(defun parse-json-string (state)
  "Parse a JSON string, returning a zero-copy substring when the contents need
no unescaping and a freshly built string otherwise."
  (expect-char state #\")
  (let ((start (ps-pos state)))
    ;; Fast path: scan ordinary characters until the closing quote.
    (loop until (ps-eof-p state)
          for character = (ps-peek state)
          for code = (char-code character)
          do (cond
               ((char= character #\")
                (ps-advance state)
                (return-from parse-json-string
                  (subseq (ps-text state) start (1- (ps-pos state)))))
               ((or (char= character #\\) (< code #x20) (<= #xD800 code #xDFFF))
                (return))
               (t
                (when (>= (- (ps-pos state) start) (ps-max-string-length state))
                  (parse-error-here state))
                (ps-advance state))))
    (when (ps-eof-p state) (parse-error-here state))
    ;; Slow path: an escape or control character forces a built string.
    (parse-escaped-string-rest state start)))
