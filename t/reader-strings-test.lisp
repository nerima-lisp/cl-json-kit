;;;; t/reader-strings-test.lisp
(in-package #:cl-json-kit/test)

(describe "strings and unicode"
  (it "decodes escapes, including surrogate pairs beyond the BMP"
    (expect (char= (char (parse "\"\\u0041\"") 0) #\A) :to-be-truthy)
    (expect (= (char-code (char (parse "\"\\uD83D\\uDE00\"") 0)) #x1F600) :to-be-truthy))

  (it-each (("\"\\uD800\"") ("\"\\uDC00\"") ("\"\\uD800\\u0041\"") ("\"\\x\""))
      "rejects the invalid string escape ~S"
      (text)
    (signals json-parse-error (parse text)))

  (it "decodes lowercase hex escapes and lowercase surrogate pairs"
    (expect (= (char-code (char (parse "\"\\u00e9\"") 0)) #xE9) :to-be-truthy)
    (expect (= (char-code (char (parse "\"\\ud83d\\ude00\"") 0)) #x1F600) :to-be-truthy))

  (it "enforces MAX-STRING-LENGTH along the escaped slow path"
    (signals json-parse-error (parse "\"a\\n\\n\"" :max-string-length 2)))

  (it "rejects raw control characters in strings"
    (signals json-parse-error (parse (format nil "\"a~Cb\"" (code-char 1)))))

  (it "round-trips every short escape through the shared escape table"
    (let ((decoded (parse "\"\\b\\f\\n\\r\\t\\\"\\\\\\/\""))
          (expected (coerce (list #\Backspace #\Page #\Newline #\Return #\Tab
                                  #\" #\\ #\/)
                            'string)))
      (expect decoded :to-equal expected)))

  (it-each (("\"\\u12") ("\"\\u00zz\""))
      "rejects the malformed \\u escape ~S"
      (text)
    (signals json-parse-error (parse text)))

  (it "enforces MAX-STRING-LENGTH on a plain run following an earlier escape"
    ;; Entering the slow path via one escape, then scanning a long unescaped
    ;; run that alone pushes the decoded length over budget, is a distinct
    ;; code path from an escape-dense string or an all-plain fast-path string.
    (let ((text (format nil "\"\\n~A\"" (make-string 200 :initial-element #\a))))
      (signals json-parse-error (parse text :max-string-length 50))
      (expect (= (length (parse text)) 201) :to-be-truthy)))

  (it "reports EOF when the slow path never finds a closing quote"
    (signals json-parse-error (parse "\"\\na")))

  (it "bounds decoded escaped-string length exactly and combines escapes beyond the BMP"
    ;; The JSON unit a\"b\\cA decodes to the six characters a"b\cA; repeating
    ;; it drives the escaped slow path over a long, mixed-escape string.
    (let* ((unit "a\\\"b\\\\c\\u0041")
           (encoded (format nil "\"~{~A~}\"" (make-list 128 :initial-element unit)))
           (expected (format nil "~{~A~}" (make-list 128 :initial-element "a\"b\\cA"))))
      (expect (string= (parse encoded :max-string-length (length expected)) expected)
              :to-be-truthy)
      (signals json-parse-error (parse encoded :max-string-length (1- (length expected)))))
    (expect (string= (parse "\"\\uD83D\\uDE00\\\"\\\\\"")
                     (format nil "~C\"\\" (code-char #x1F600)))
            :to-be-truthy)
    (let* ((tail (make-string 10000 :initial-element #\a))
           (value (parse (format nil "[\"\\\"\",\"~A\"]" tail))))
      (expect (string= (aref value 0) "\"") :to-be-truthy)
      (expect (string= (aref value 1) tail) :to-be-truthy))))
