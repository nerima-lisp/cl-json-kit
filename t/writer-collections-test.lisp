;;;; t/writer-scalars-test.lisp
(in-package #:cl-json-kit/test)

(describe "writing scalars"
  (it "stringifies primitive values"
    (expect "hello" :to-stringify-as "\"hello\"")
    (expect 42 :to-stringify-as "42")
    (expect t :to-stringify-as "true")
    (expect +json-false+ :to-stringify-as "false")
    (expect +json-null+ :to-stringify-as "null")
    (expect nil :to-stringify-as "[]")
    (expect (parse "false") :to-stringify-as "false")
    (expect (parse "null") :to-stringify-as "null"))

  (it "supports custom null/false markers"
    (let ((null-marker (list :null))
          (false-marker (list :false)))
      (expect (string= (stringify (vector null-marker false-marker)
                                  :null-value null-marker :false-value false-marker)
                       "[null,false]")
              :to-be-truthy))))

(describe "writing aggregates"
  (it "maps Lisp types to JSON shapes purely by type"
    (expect #(1 2 #(3 4)) :to-stringify-as "[1,2,[3,4]]")
    (expect (list 1 2 3) :to-stringify-as "[1,2,3]")
    (expect (list "a" "b") :to-stringify-as "[\"a\",\"b\"]")
    (let ((table (make-hash-table :test #'equal)))
      (setf (gethash "a" table) 1)
      (expect table :to-stringify-as "{\"a\":1}")))

  ;; The whole point of the library: a list of conses is an array of arrays,
  ;; never silently reinterpreted as an object.
  (it "never guesses object intent from a list of pairs"
    (expect (list (list 1 2) (list 3 4)) :to-stringify-as "[[1,2],[3,4]]")
    (signals json-serialization-error (stringify (cons 1 2))))

  (it "refuses keywords and otherwise unsupported types"
    (signals json-serialization-error (stringify :foo))
    (signals json-serialization-error (stringify #'car)))

  (it "writes an alist as an object only through the explicit wrapper"
    (let ((json (stringify (alist->json-object (list (cons "a" 1) (cons "b" 2))))))
      (expect (and (search "\"a\":1" json) (search "\"b\":2" json)) :to-be-truthy)
      (expect (char= (char json 0) #\{) :to-be-truthy)
      (expect (char= (char json (1- (length json))) #\}) :to-be-truthy))))

(describe "writing numbers"
  (it "emits finite floats as JSON numbers with exact round trips"
    (dolist (value (list 1.5d0 -2.25f0 0.0f0 -0.0f0 0.0d0 -0.0d0
                         least-positive-normalized-single-float
                         most-positive-single-float
                         least-positive-normalized-double-float
                         most-positive-double-float
                         (float 16777215 1.0f0)
                         (float 9007199254740991 1.0d0)))
      (let* ((text (json-kit::json-float-string value))
             (*read-default-float-format* (type-of value)))
        (expect (find-if (lambda (character) (find character "dDfFsSlL" :test #'char=)) text)
                :to-be-falsy)
        (expect (numberp (parse text)) :to-be-truthy)
        (multiple-value-bind (roundtrip end) (read-from-string text)
          (expect (= end (length text)) :to-be-truthy)
          (expect (typep roundtrip (type-of value)) :to-be-truthy)
          (expect (= roundtrip value) :to-be-truthy)
          (when (zerop value)
            (expect (= (float-sign roundtrip) (float-sign value)) :to-be-truthy))))))

  (it "serializes a float identically under every *READ-DEFAULT-FLOAT-FORMAT*"
    ;; The printer appends a Lisp exponent marker whenever the float's format
    ;; differs from *READ-DEFAULT-FLOAT-FORMAT*, so before this was pinned down
    ;; 3.14d0 serialized as "3.14e0" in a default image and as "3.14" in one
    ;; whose default had been set to DOUBLE-FLOAT.  Output must depend on the
    ;; value alone, never on ambient state of the calling image.
    (with-soft-assertions
      (dolist (value (list 3.14d0 1.5d0 1.0d0 1.0d308 1.0d-5
                           3.14f0 1.5f0 1.0f0 1.0f10))
        (let ((under-single (let ((*read-default-float-format* 'single-float))
                              (stringify value)))
              (under-double (let ((*read-default-float-format* 'double-float))
                              (stringify value))))
          (expect (list value under-single) :to-equal (list value under-double))))
      (let ((*read-default-float-format* 'single-float))
        (expect 3.14d0 :to-stringify-as "3.14")
        (expect 1.0d308 :to-stringify-as "1.0e308"))
      (let ((*read-default-float-format* 'double-float))
        (expect 1.5f0 :to-stringify-as "1.5"))))

  (it-each ((1/2 "0.5") (-1/40 "-0.025") (123/25 "4.92"))
      "writes the terminating ratio ~S as ~S"
      (value expected)
    (expect value :to-stringify-as expected))

  (it "preserves negative zero and rejects non-terminating ratios"
    (expect -0.0d0 :to-stringify-as "-0.0")
    (signals json-serialization-error (stringify (/ 1 3)))
    (expect (string= (stringify (/ 1 3) :number-encoder (constantly "0.333")) "0.333")
            :to-be-truthy))

  (it "rejects unsupported and non-finite numbers"
    (signals json-serialization-error (stringify 1/3))
    #+sbcl
    (sb-int:with-float-traps-masked (:invalid :divide-by-zero :overflow)
      (let ((zero 0d0) (one 1d0))
        (signals json-serialization-error (stringify (/ zero zero)))
        (signals json-serialization-error (stringify (/ one zero))))))

  (it "rejects unsupported number types and over-budget integers"
    (signals json-serialization-error (stringify #C(1 2)))
    (signals json-serialization-error (stringify 123456 :max-output-length 3)))

  (it "validates the output of a user number encoder"
    (expect (string= (stringify 12 :number-encoder (constantly "1.2e+3")) "1.2e+3") :to-be-truthy)
    (dolist (bad (list "01" "1." "1e" ".5" "+1" ""))
      (signals json-serialization-error (stringify 12 :number-encoder (constantly bad))))
    (dolist (code (list #xFF11 #x0661 #x0967))
      (signals json-serialization-error
        (stringify 12 :number-encoder (constantly (string (code-char code)))))))

  (it "accepts an fbound symbol as NUMBER-ENCODER"
    (expect (string= (stringify 12 :number-encoder 'symbol-number-encoder) "42") :to-be-truthy)))
