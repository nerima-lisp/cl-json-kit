;;;; t/writer-strings-test.lisp
(in-package #:cl-json-kit/test)

(describe "string escaping"
  (it "escapes quotes, backslashes, solidus-free text, and control characters"
    (let ((input (concatenate 'string "a\"b\\c" (string #\Newline) "d" (string #\Tab) "e")))
      (expect input :to-stringify-as "\"a\\\"b\\\\c\\nd\\te\""))
    (expect (string (code-char #x01)) :to-stringify-as "\"\\u0001\""))

  (it "escapes correctly across plain-run boundaries"
    ;; Escapes at the start, end, and interior of a plain run must all survive
    ;; the run-flushing encode path unchanged.
    (dolist (case (list (cons "plain" "\"plain\"")
                        (cons "\"plain" "\"\\\"plain\"")
                        (cons "plain\"" "\"plain\\\"\"")
                        (cons "a\"b\\c" "\"a\\\"b\\\\c\"")
                        (cons (concatenate 'string "ab" (string #\Newline) "cd"
                                           (string #\Tab) "ef")
                              "\"ab\\ncd\\tef\"")))
      (expect (string= (stringify (car case)) (cdr case)) :to-be-truthy)))

  (it "truncates escaped output at exact character boundaries"
    ;; ab"cd escapes to "ab\"cd" (8 characters); each budget must stop the
    ;; stream at the same byte the char-accurate writer would.
    (let ((input "ab\"cd"))
      (expect (string= (stringify input :max-output-length 8) "\"ab\\\"cd\"") :to-be-truthy)
      (signals json-serialization-error (stringify input :max-output-length 7))
      (dolist (case (list (cons 4 "\"ab")
                          (cons 5 "\"ab\\\"")
                          (cons 7 "\"ab\\\"cd")))
        (let ((stream (make-string-output-stream)))
          (handler-case (write-json input stream :max-output-length (car case))
            (json-serialization-error ()))
          (expect (string= (get-output-stream-string stream) (cdr case)) :to-be-truthy)))))

  (it "rejects raw surrogate characters"
    (let ((surrogate (code-char #xd800)))
      (when surrogate
        (signals json-serialization-error (stringify (string surrogate)))
        (signals json-serialization-error
          (stringify (concatenate 'string "plain" (string surrogate) "tail"))))))

  (it "accounts dense escaped output at exact maximum-length boundaries"
    (let* ((unit (concatenate 'string "\"" "\\"
                              (string (code-char #x00))
                              (string (code-char #x1f))
                              "ab"))
           (input (with-output-to-string (stream)
                    (loop repeat 24
                          do (write-string unit stream))
                    (write-string "tail" stream)))
           (expected (with-output-to-string (stream)
                       (write-char #\" stream)
                       (loop repeat 24
                             do (write-string "\\\"" stream)
                                (write-string "\\\\" stream)
                                (write-string "\\u0000" stream)
                                (write-string "\\u001F" stream)
                                (write-string "ab" stream))
                       (write-string "tail\"" stream)))
           (exact-length (length expected)))
      (progn
        (expect (= (length input) 148) :to-be-truthy)
        (dolist (size (list 4095 4096 8193))
          (let* ((dense-input (make-string size :initial-element #\"))
                 (dense-expected
                   (with-output-to-string (stream)
                     (write-char #\" stream)
                     (loop repeat size do (write-string "\\\"" stream))
                     (write-char #\" stream))))
            (expect (stringify dense-input) :to-equal dense-expected)))
        (let* ((late-input
                 (concatenate (quote string)
                              (make-string 12 :initial-element #\")
                              (make-string 8168 :initial-element #\a)
                              "\"\\"
                              (string (code-char #x00))))
               (late-expected
                 (with-output-to-string (stream)
                   (write-char #\" stream)
                   (loop repeat 12 do (write-string "\\\"" stream))
                   (loop repeat 8168 do (write-char #\a stream))
                   (write-string "\\\"" stream)
                   (write-string "\\\\" stream)
                   (write-string "\\u0000" stream)
                   (write-char #\" stream))))
          (expect (stringify late-input) :to-equal late-expected)))
      (expect (>= (loop for index below 128
                        for character = (char input index)
                        count (or (char= character #\")
                                  (char= character #\\)))
                  12)
              :to-be-truthy)
      (dolist (case (list (cons (1- exact-length) t)
                          (cons exact-length nil)
                          (cons (1+ exact-length) nil)))
        (let ((stream (make-string-output-stream))
              (signalled nil)
              (json-kit::*json-output-count* 0)
              (json-kit::*json-maximum-output-length* (car case)))
          (let ((json-kit::*json-output-stream* stream))
            (handler-case (json-kit::write-json-string input)
              (json-serialization-error ()
                (setf signalled t))))
          (let ((output (get-output-stream-string stream)))
            (expect (eq signalled (cdr case)) :to-be-truthy)
            (expect (string= output
                             (if (cdr case)
                                 (subseq expected 0 (car case))
                                 expected))
                    :to-be-truthy)
            (expect (= json-kit::*json-output-count* (length output))
                    :to-be-truthy))))))

  (it "uses the buffered escape path for a long, escape-dense string with no output budget"
    ;; WRITE-JSON-STRING's buffered branch activates only when
    ;; *JSON-MAXIMUM-OUTPUT-LENGTH* is NIL and the string is both long
    ;; (>= 128 characters) and escape-dense (>= 12 quote/backslash escapes in
    ;; its first 128 characters). STRINGIFY/WRITE-JSON default MAX-OUTPUT-LENGTH
    ;; to a finite bound, so :MAX-OUTPUT-LENGTH NIL is the only way to reach it.
    (let* ((size 200)
           (input (make-string size :initial-element #\"))
           (expected (with-output-to-string (stream)
                       (write-char #\" stream)
                       (loop repeat size do (write-string "\\\"" stream))
                       (write-char #\" stream))))
      (expect (string= (stringify input :max-output-length nil) expected) :to-be-truthy)
      (expect (string= (stringify input) expected) :to-be-truthy))))

(describe "bounded dense string escaping"
  (it "keeps quote and backslash escapes atomic"
    (dolist (escape (list #\" #\\))
      (let ((input (make-string 128 :initial-element #\a))
            (stream (make-string-output-stream)))
        (fill input escape :end 12)
        (signals json-serialization-error
          (write-json input stream :max-output-length 2))
        (expect (string= (get-output-stream-string stream) (string #\"))
                :to-be-truthy)))))
