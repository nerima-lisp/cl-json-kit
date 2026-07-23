;;;; t/reader-test.lisp

(in-package #:cl-json-kit/test)

(it "parses basic scalar types"
  (expect (string= (parse "\"hello\"" :key-type :string) "hello") :to-be-truthy)
  (expect (= (parse "42") 42) :to-be-truthy)
  (expect (= (parse "-3.5") -3.5d0) :to-be-truthy)
  (expect (= (parse "1e2") 100.0d0) :to-be-truthy)
  (expect (eq (parse "true") t) :to-be-truthy)
  (expect (eq (parse "false") :false) :to-be-truthy)
  (expect (eq (parse "null") :null) :to-be-truthy))

(it "parses nested objects and arrays into hash-tables by default"
  (let ((value (parse "{\"a\": 1, \"b\": [1, 2, {\"c\": true}]}")))
    (expect (typep value 'hash-table) :to-be-truthy)
    (expect (= (gethash :A value) 1) :to-be-truthy)
    (let ((inner (gethash :B value)))
      (expect (typep inner 'simple-vector) :to-be-truthy)
      (expect (= (length inner) 3) :to-be-truthy)
      (expect (eq (gethash :C (aref inner 2)) t) :to-be-truthy))))

(it "parses objects into alists when object-type is :alist"
  (let ((value (parse "{\"x\": 1, \"y\": {\"z\": 2}}" :object-type :alist)))
    (expect (listp value) :to-be-truthy)
    (expect (= (cdr (assoc :x value)) 1) :to-be-truthy)
    (let ((inner (cdr (assoc :y value))))
      (expect (listp inner) :to-be-truthy)
      (expect (= (cdr (assoc :z inner)) 2) :to-be-truthy))))

(it "parses arrays as lists when array-type is :list"
  (let ((value (parse "[1, [2, 3], 4]" :array-type :list)))
    (expect (listp value) :to-be-truthy)
    (expect (equal value (list 1 (list 2 3) 4)) :to-be-truthy)))

(it "keeps object keys as raw strings when key-type is :string"
  (let ((value (parse "{\"Foo\": 1}" :object-type :alist :key-type :string)))
    (expect (string= (car (first value)) "Foo") :to-be-truthy)))

(it "decodes \\uXXXX surrogate pairs into a single character"
  ;; U+1F600 GRINNING FACE, encoded as the UTF-16 surrogate pair D83D DE00.
  (let ((value (parse "\"\\uD83D\\uDE00\"" :key-type :string)))
    (expect (= (length value) 1) :to-be-truthy)
    (expect (= (char-code (char value 0)) #x1F600) :to-be-truthy)))

(it "signals json-parse-error with position and context on unterminated strings"
  (handler-case
      (progn (parse "\"unterminated" :context "unit-test")
             (error "expected a json-parse-error to be signalled"))
    (json-parse-error (c)
      (expect (string= (json-parse-error-context c) "unit-test") :to-be-truthy)
      (expect (integerp (json-parse-error-position c)) :to-be-truthy)))
  (signals json-parse-error (parse "\"unterminated")))

(it "signals json-parse-error on trailing commas"
  (signals json-parse-error (parse "[1, 2, ]"))
  (signals json-parse-error (parse "{\"a\": 1, }")))

(it "accepts a timeout-seconds bound for small, well-formed input"
  (expect (equal (parse "[1, 2, 3]" :array-type :list :timeout-seconds 5) '(1 2 3))
          :to-be-truthy))
