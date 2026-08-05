;;;; t/writer-collections-test.lisp
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

