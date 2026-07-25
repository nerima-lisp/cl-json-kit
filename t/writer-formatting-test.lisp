;;;; t/writer-formatting-test.lisp
(in-package #:cl-json-kit/test)

(describe "pretty printing and key ordering"
  (it "indents nested output when :PRETTY"
    (let ((table (make-hash-table :test #'equal)))
      (setf (gethash "a" table) 1)
      (expect (string= (stringify table :pretty t) (format nil "{~%  \"a\": 1~%}")) :to-be-truthy))
    (expect (string= (stringify (list 1 2) :pretty t) (format nil "[~%  1,~%  2~%]")) :to-be-truthy))

  (it "sorts object keys deterministically"
    (let ((table (make-hash-table :test #'equal)))
      (setf (gethash "z" table) 1 (gethash "a" table) 2)
      (expect (string= (stringify table :sort-keys t) "{\"a\":2,\"z\":1}") :to-be-truthy)
      (expect (string= (stringify table :sort-keys t :pretty t)
                       (format nil "{~%  \"a\": 2,~%  \"z\": 1~%}"))
              :to-be-truthy)))

  (it "serializes a large unsorted object straight from its hash table"
    (let ((table (make-hash-table :test #'equal)))
      (loop for index below 10000 do (setf (gethash (format nil "key-~D" index) table) index))
      (let ((decoded (parse (stringify table :sort-keys nil))))
        (expect (= (hash-table-count decoded) 10000) :to-be-truthy)
        (expect (= (gethash "key-0" decoded) 0) :to-be-truthy)
        (expect (= (gethash "key-9999" decoded) 9999) :to-be-truthy)))))
