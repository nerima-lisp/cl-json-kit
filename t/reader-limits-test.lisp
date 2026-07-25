;;;; t/reader-limits-test.lisp
(in-package #:cl-json-kit/test)

(describe "resource bounds and truncation"
  (it "honours element, depth, string, and number limits"
    (expect (parse "[]" :max-array-elements 0) :to-equalp #())
    (signals json-parse-error (parse "[0]" :max-array-elements 0))
    (expect (= (hash-table-count (parse "{}" :max-object-members 0)) 0) :to-be-truthy)
    (signals json-parse-error (parse "{\"a\":0}" :max-object-members 0))
    (expect (parse "[]" :max-depth 1) :to-equalp #())
    (signals json-parse-error (parse "[[]]" :max-depth 1))
    (expect "\"a\"" :to-parse-as "a")
    (signals json-parse-error (parse "\"ab\"" :max-string-length 1))
    (expect (= (parse "1" :max-number-length 1) 1) :to-be-truthy)
    (signals json-parse-error (parse "12" :max-number-length 1))
    (signals json-parse-error (parse "null" :max-input-length 3)))

  (it-each (("") ("[") ("[1") ("[1,") ("{") ("{\"a\"") ("{\"a\":")
            ("\"") ("\"\\") ("tru") ("-") ("1e"))
      "rejects the truncated input ~S"
      (text)
    (signals json-parse-error (parse text)))

  (it-each ((:max-depth -1) (:max-array-elements 1.5) (:max-exact-exponent -1))
      "rejects the non-integer resource limit ~S ~S"
      (option value)
    (signals json-parse-error (parse "null" option value)))

  (it "accepts only RFC whitespace and rejects trailing input"
    (dolist (code (list #x20 #x09 #x0A #x0D))
      (expect (= (parse (format nil "~C1~C"
                                (code-char code)
                                (code-char code)))
                 1)
              :to-be-truthy))
    (signals json-parse-error (parse (format nil "~C1" (code-char #x0C))))
    (signals json-parse-error (parse "true false"))
    (signals json-parse-error (parse "[]x"))))
