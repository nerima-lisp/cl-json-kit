;;;; t/writer-alist-test.lisp
(in-package #:cl-json-kit/test)

(describe "alist / object conversions"
  (it "round-trips hash-table objects through json-object->alist"
    (let ((table (make-hash-table :test #'equal)))
      (setf (gethash "a" table) 1 (gethash "b" table) 2)
      (let ((alist (json-object->alist table)))
        (expect (= (cdr (assoc "a" alist :test #'string=)) 1) :to-be-truthy)
        (expect (= (cdr (assoc "b" alist :test #'string=)) 2) :to-be-truthy))))

  (it "validates and copies a plain alist through json-object->alist"
    (let* ((source (list (cons "a" 1) (cons "b" 2)))
           (result (json-object->alist source)))
      (expect result :to-equal source)
      ;; A fresh copy, not the same conses.
      (expect (eq result source) :to-be-falsy)
      (signals json-serialization-error (json-object->alist (list "not-a-pair")))))

  (it "round-trips a nested value through parse and stringify"
    (let* ((original "{\"name\":\"a\",\"nums\":[1,2,3],\"ok\":true}")
           (value (parse original :object-type :alist :array-type :list)))
      (expect (cdr (assoc "nums" value :test #'string=)) :to-stringify-as "[1,2,3]")
      (expect (search "\"name\":\"a\"" (stringify (alist->json-object value))) :to-be-truthy)
      (expect (equalp (parse (stringify (parse original))) (parse original)) :to-be-truthy)))

  (it "rejects circular alists during conversion"
    (let ((alist (list (cons "a" 1))))
      (setf (cdr alist) alist)
      (signals json-serialization-error (alist->json-object alist)))
    (let* ((first (list (cons "a" 1)))
           (second (list (cons "b" 2))))
      (setf (cdr first) second (cdr second) first)
      (signals json-serialization-error (alist->json-object first))))

  (it "validates conversion shape, key type, and element bounds"
    (expect (= (hash-table-count (alist->json-object '() :max-elements 0)) 0) :to-be-truthy)
    (expect (= (gethash "a" (alist->json-object (list (cons "a" 1)) :max-elements 1)) 1)
            :to-be-truthy)
    (signals json-serialization-error (alist->json-object (list (cons "a" 1)) :max-elements 0))
    (signals json-serialization-error (alist->json-object (cons (cons "a" 1) 2)))
    (signals json-serialization-error (alist->json-object (list "malformed")))
    ;; Non-string keys of several types drive the diagnostic-snippet branches.
    (signals json-serialization-error (alist->json-object (list (cons 1 "integer key"))))
    (signals json-serialization-error (alist->json-object (list (cons :sym "symbol key"))))
    (signals json-serialization-error (alist->json-object (list (cons 1.5 "float key"))))
    (signals json-serialization-error
      (alist->json-object (list (cons (expt 10 400) "huge integer key"))))
    (signals json-serialization-error (alist->json-object '() :duplicate-key-policy "bad"))
    (let ((key (list :key)))
      (setf (cdr key) key)
      (signals json-serialization-error (alist->json-object (list (cons key 1)))))
    (signals json-serialization-error (alist->json-object '() :max-elements (- (ash 1 100000)))))

  (it-each ((:first 1) (:last 2))
      "applies explicit conversion duplicate policy ~S"
      (policy expected)
    (let ((duplicates (list (cons "same" 1) (cons "same" 2))))
      (expect (= (gethash "same" (alist->json-object duplicates :duplicate-key-policy policy))
                 expected)
              :to-be-truthy)))

  (it "signals on conversion duplicates under :ERROR and :UNKNOWN"
    (let ((duplicates (list (cons "same" 1) (cons "same" 2))))
      (signals json-serialization-error (alist->json-object duplicates))
      (signals json-serialization-error
        (alist->json-object duplicates :duplicate-key-policy :unknown))))

  (it "preserves ordered and duplicate members and defends its own copy"
    (let* ((members (list (cons "same" 1) (cons "other" 2) (cons "same" 3)))
           (object (alist->json-object members :duplicate-key-policy :preserve))
           (exposed (json-object-members object)))
      (expect (json-object-p object) :to-be-truthy)
      (expect (json-object->alist object) :to-equal members)
      (setf (cdr (first exposed)) 99)
      (expect (json-object->alist object) :to-equal members)
      (expect object :to-stringify-as "{\"same\":1,\"other\":2,\"same\":3}")
      (expect (string= (stringify object :sort-keys t) "{\"same\":1,\"other\":2,\"same\":3}")
              :to-be-truthy)
      (expect (string= (stringify object :pretty t :indent 2)
                       (format nil "{~%  \"same\": 1,~%  \"other\": 2,~%  \"same\": 3~%}"))
              :to-be-truthy)))

  (it "enforces ordered-object serialization boundaries"
    (signals json-serialization-error
      (stringify (make-json-object (list (cons "a" 1) (cons "b" 2))) :max-elements 1))
    (signals json-serialization-error
      (stringify (make-json-object (list (cons "a" "long"))) :max-output-length 5))
    (signals json-serialization-error
      (stringify (make-json-object (list (cons "nested" (vector 1)))) :max-depth 0))
    (let* ((object (make-json-object (list (cons "self" nil))))
           (member (first (json-object-members object))))
      (setf (cdr member) object)
      (expect object :to-stringify-as "{\"self\":[]}")))

  (it "bounds and validates object conversion before enumeration"
    (let ((table (make-hash-table :test #'equal)))
      (setf (gethash "a" table) 1)
      (signals json-serialization-error (json-object->alist table :max-elements 0))
      (expect (= (cdr (assoc "a" (json-object->alist table :max-elements 1) :test #'string=)) 1)
              :to-be-truthy))
    (let ((table (make-hash-table :test #'equal)))
      (setf (gethash 1 table) "bad")
      (signals json-serialization-error (json-object->alist table)))
    (let ((table (alist->json-object (list (cons "a" 1)) :max-elements most-positive-fixnum)))
      (expect (= (hash-table-count table) 1) :to-be-truthy))))
