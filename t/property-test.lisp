;;;; t/property-test.lisp
;;;;
;;;; Property-based specs: instead of a handful of chosen examples, assert an
;;;; invariant over many generated inputs and let cl-weave shrink any
;;;; counterexample to a minimal failing value.
(in-package #:cl-json-kit/test)

(describe "round-trip properties"
  (it-property "integers round-trip through JSON"
      ((n (gen-json-integer)))
    (expect n :to-round-trip))

  (it-property "escape-stressed strings round-trip through JSON"
      ((text (gen-json-string)))
    (expect text :to-round-trip))

  (it-property "integer vectors round-trip through JSON"
      ((vector (gen-vector (gen-integer :min -1000 :max 1000) :max-length 8)))
    (expect vector :to-round-trip))

  (it-property "parse-prefix reports the exact consumed length of an integer prefix"
      ((n (gen-integer :min 0 :max 1000000)))
    (let ((text (format nil "~D tail" n)))
      (multiple-value-bind (value end) (parse-prefix text)
        (expect value :to-be n)
        (expect end :to-be (length (princ-to-string n))))))

  (it-fuzz "parse never signals anything but a JSON-PARSE-ERROR on arbitrary input"
      ((text (gen-string :alphabet +json-syntax-alphabet+ :max-length 64)))
      (:trials 200)
    (handler-case (parse text)
      (json-parse-error () nil)))

  (it-property "sorted object keys emerge in nondecreasing order"
      ((keys (gen-list (gen-string :alphabet "abcde" :min-length 1 :max-length 4)
                       :max-length 6)))
    (let ((table (make-hash-table :test #'equal)))
      (loop for key in keys
            for index from 0
            do (setf (gethash key table) index))
      (let* ((decoded (parse (stringify table :sort-keys t) :object-type :alist))
             (decoded-keys (mapcar #'car decoded)))
        (expect (equal decoded-keys (sort (copy-list decoded-keys) #'string<))
                :to-be-truthy)))))
