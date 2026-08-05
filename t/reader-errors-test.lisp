;;;; t/reader-errors-test.lisp
(in-package #:cl-json-kit/test)

(describe "error reporting"
  (it "reports stable position, line, column, and structured path"
    ;; Every field below is an independent claim about one condition; WITH-SOFT-ASSERTIONS
    ;; reports all of them together instead of stopping at the first mismatch.
    (with-soft-assertions
      (let ((condition
              (capture-json-parse-error
               (parse (format nil "{\"outer\": [0,~% nope]}") :context "unit-test"))))
        (expect (= (json-parse-error-position condition) 15) :to-be-truthy)
        (expect (= (json-parse-error-line condition) 2) :to-be-truthy)
        (expect (= (json-parse-error-column condition) 2) :to-be-truthy)
        (expect (json-parse-error-path condition) :to-equal (list "outer" 1))
        (expect (stringp (json-parse-error-expected condition)) :to-be-truthy)
        (expect (string= (json-parse-error-context condition) "unit-test") :to-be-truthy)
        (expect (stringp (json-parse-error-text condition)) :to-be-truthy))))

  (it-each (((#\Return)) ((#\Newline)) ((#\Return #\Newline)))
      "counts the line break ~S as one source line while keeping the path"
      (break-characters)
    (let* ((newline (coerce break-characters 'string))
           (condition
             (capture-json-parse-error (parse (format nil "{\"a\":[0,~A ?]}" newline)))))
      (expect (= (json-parse-error-line condition) 2) :to-be-truthy)
      (expect (= (json-parse-error-column condition) 2) :to-be-truthy)
      (expect (json-parse-error-path condition) :to-equal (list "a" 1))))

  (it "escapes a raw tab and a raw backspace inside the captured error snippet"
    (let ((tab-condition (capture-json-parse-error (parse (format nil "~C]" #\Tab))))
          (backspace-condition (capture-json-parse-error (parse (format nil "~C@" (code-char 8))))))
      (expect (search "\\t" (json-parse-error-text tab-condition)) :to-be-truthy)
      (expect (search "\\b" (json-parse-error-text backspace-condition)) :to-be-truthy)))

  (it "positions the error at the overrun when MAX-STRING-LENGTH is exceeded by an escape"
    (let ((condition (capture-json-parse-error (parse "\"\\u0041\"" :max-string-length 0))))
      (expect (= (json-parse-error-position condition) 7) :to-be-truthy)
      (expect (= (json-parse-error-line condition) 1) :to-be-truthy)
      (expect (= (json-parse-error-column condition) 8) :to-be-truthy)))

  (it "reports exact EOF diagnostics at array and generic object values"
    (dolist (case (list (list "[1,   " (list :array-type :vector) 6 (list 1))
                        (list "[1,   " (list :array-type :list) 6 (list 1))
                        (list "{\"a\":   "
                              (list :object-type :alist :duplicate-key-policy :last)
                              8
                              (list "a"))))
      (destructuring-bind (text options position path) case
        (let ((condition (capture-json-parse-error
                          (apply (function parse) text options))))
          (expect (= (json-parse-error-position condition) position) :to-be-truthy)
          (expect (json-parse-error-path condition) :to-equal path)
          (expect (string= (json-parse-error-expected condition) "JSON value")
                  :to-be-truthy)))))

  (it "preserves the trailing-comma diagnostic after RFC whitespace"
    (dolist (array-type (list :vector :list))
      (let ((condition
              (capture-json-parse-error (parse "[1, ]" :array-type array-type))))
        (expect (= (json-parse-error-position condition) 4) :to-be-truthy)
        (expect (json-parse-error-path condition) :to-equal nil)
        (expect (string= (json-parse-error-expected condition) "array value")
                :to-be-truthy))))

  (it "tracks the structured path only while parsing the offending member value"
    (dolist (case (list (list "{\"a\":[{\"b\":[0,?]}]}" (list "a" 0 "b" 1))
                        (list "[[0],[1,?]]" (list 1 1))
                        (list "[[0],?]" (list 1))
                        (list "{\"outer\":{\"bad\\q\":1}}" (list "outer"))
                        (list "{\"outer\":{\"bad\" 1}}" (list "outer"))
                        (list "{\"outer\":[0,]}" (list "outer"))
                        (list "{\"outer\":[0 x]}" (list "outer"))))
      (destructuring-bind (text expected-path) case
        (let ((condition (capture-json-parse-error (parse text))))
          (expect (json-parse-error-path condition) :to-equal expected-path)))))

  (it "reports exact coordinates and diagnostics for array-position errors"
    (dolist (case (list (list (format nil "[0,~% ?]") nil 5 2 2 (list 1) "JSON value")
                        (list "{\"outer\":[0,]}" nil 12 1 13 (list "outer") "array value")
                        (list "[1,2]" (list :max-array-elements 1) 3 1 4 nil
                              "fewer array elements")))
      (destructuring-bind (text options position line column path diagnostic) case
        (let ((condition (capture-json-parse-error
                          (apply #'parse text (list* :context "array-regression" options)))))
          (expect (= (json-parse-error-position condition) position) :to-be-truthy)
          (expect (= (json-parse-error-line condition) line) :to-be-truthy)
          (expect (= (json-parse-error-column condition) column) :to-be-truthy)
          (expect (json-parse-error-path condition) :to-equal path)
          (expect (string= (json-parse-error-expected condition) diagnostic) :to-be-truthy)
          (expect (string= (json-parse-error-context condition) "array-regression")
                  :to-be-truthy))))))
