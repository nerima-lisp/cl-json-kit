;;;; t/writer-limits-test.lisp
(in-package #:cl-json-kit/test)

(describe "output bounds and option validation"
  (it "enforces exact and plus-one output-length limits"
    (let ((stream (make-string-output-stream)))
      (write-json "a" stream :max-output-length 3)
      (expect (string= (get-output-stream-string stream) "\"a\"") :to-be-truthy))
    (signals json-serialization-error (write-json "a" (make-string-output-stream) :max-output-length 2))
    (expect (string= (stringify #() :max-elements 0) "[]") :to-be-truthy)
    (signals json-serialization-error (stringify #(1) :max-elements 0)))

  (it "enforces output-length and element limits on the right value kinds"
    (signals json-serialization-error (stringify "abc" :max-output-length 4))
    (signals json-serialization-error (stringify #(1 2) :max-elements 1)))

  (it "validates depth and indent"
    (signals json-serialization-error (stringify #(#(1)) :max-depth 0))
    (signals json-serialization-error (stringify #(1) :indent -1))
    (signals json-serialization-error (stringify #(1) :indent 1.5)))

  (it-each ((:max-depth -1) (:max-depth 1.5)
            (:max-elements -1) (:max-elements 1.5)
            (:max-output-length -1) (:max-output-length 1.5))
      "rejects the non-integer or negative resource limit ~S ~S"
      (option value)
    (signals json-serialization-error (stringify #(1) option value)))

  (it "bounds terminating ratios before the expensive conversion"
    (let ((value (/ 1 (expt 2 8))))
      (expect (string= (stringify value :max-output-length 10) "0.00390625") :to-be-truthy)
      (signals json-serialization-error (stringify value :max-output-length 9)))
    (let ((huge (/ 1 (expt 2 128))))
      (signals json-serialization-error (stringify huge :max-output-length 32))
      (expect (string= (stringify huge :max-output-length 1 :number-encoder (constantly "0")) "0")
              :to-be-truthy))
    (signals json-serialization-error
      (stringify (/ (1+ (ash 1 128)) (ash 1 128)) :max-output-length 32)))

  (it "validates options in order without writing output"
    (dolist (case
             (list
              (list (list :indent -1
                          :max-depth -1
                          :max-elements -1
                          :max-output-length -1)
                    "INDENT must be a non-negative integer, not -1")
              (list (list :max-depth -1
                          :max-elements -1
                          :max-output-length -1)
                    "MAX-DEPTH must be NIL or a non-negative integer, not -1")
              (list (list :max-depth nil
                          :max-elements -1
                          :max-output-length -1)
                    "MAX-ELEMENTS must be NIL or a non-negative integer, not -1")
              (list (list :max-depth nil
                          :max-elements nil
                          :max-output-length -1)
                    "MAX-OUTPUT-LENGTH must be NIL or a non-negative integer, not -1")))
      (destructuring-bind (options expected-message) case
        (let ((stream (make-string-output-stream)))
          (handler-case
              (progn
                (apply #'write-json #(1) stream options)
                (error "Expected option validation to fail"))
            (json-serialization-error (condition)
              (expect (string= (json-serialization-error-message condition)
                               expected-message)
                      :to-be-truthy)))
          (expect (string= (get-output-stream-string stream) "")
                  :to-be-truthy))))))

(describe "cycles and shape validation"
  (it "rejects circular aggregates but permits shared acyclic subtrees"
    (let ((cyclic (list 1)))
      (setf (cdr cyclic) cyclic)
      (signals json-serialization-error (stringify cyclic)))
    (let ((vector (vector nil)))
      (setf (aref vector 0) vector)
      (signals json-serialization-error (stringify vector)))
    (let ((table (make-hash-table :test #'equal)))
      (setf (gethash "self" table) table)
      (signals json-serialization-error (stringify table)))
    (let ((child (vector 1)))
      (expect (vector child child) :to-stringify-as "[[1],[1]]")))

  (it "validates long, circular, improper, and bounded lists"
    (let* ((count 20000)
           (json (stringify (make-list count :initial-element 0))))
      (expect (= (length json) (1+ (* count 2))) :to-be-truthy)
      (expect (char= (char json 0) #\[) :to-be-truthy)
      (expect (char= (char json (1- (length json))) #\]) :to-be-truthy))
    (let* ((cycle (list 2 3 4))
           (value (cons 1 cycle)))
      (setf (cdr (last cycle)) cycle)
      (signals json-serialization-error (stringify value)))
    (signals json-serialization-error (stringify (list* 1 2 3)))
    (expect (list 1 2 3) :to-stringify-as "[1,2,3]")
    (signals json-serialization-error (stringify (list 1 2 3) :max-elements 2)))

  (it "requires unique string hash-table keys"
    (let ((table (make-hash-table :test #'eq)))
      (setf (gethash 1 table) "bad")
      (signals json-serialization-error (stringify table)))
    (let ((table (make-hash-table :test #'eq)))
      (setf (gethash (copy-seq "same") table) 1
            (gethash (copy-seq "same") table) 2)
      (signals json-serialization-error (stringify table))))

  (it "serializes an equalp hash table with its single coalesced member"
    (let ((table (make-hash-table :test #'equalp)))
      (setf (gethash "same" table) 1
            (gethash "SAME" table) 2)
      (let ((decoded (parse (stringify table))))
        (expect (= (hash-table-count decoded) 1) :to-be-truthy)
        (expect (= (loop for value being the hash-values of decoded
                         return value)
                   2)
                :to-be-truthy))))

  (it "creates cycle tracking lazily and clears marks on exit"
    (let ((seen :unset))
      (expect
        (string=
          (stringify 1 :number-encoder
            (lambda (number)
              (declare (ignore number))
              (setf seen json-kit::*json-active-aggregates*)
              "1"))
          "1")
        :to-be-truthy)
      (expect (null seen) :to-be-truthy))
    (let ((seen nil))
      (expect
        (string=
          (stringify #(1) :number-encoder
            (lambda (number)
              (declare (ignore number))
              (setf seen json-kit::*json-active-aggregates*)
              "1"))
          "[1]")
        :to-be-truthy)
      (expect (hash-table-p seen) :to-be-truthy)
      (expect (zerop (hash-table-count seen)) :to-be-truthy))
    (let ((seen nil))
      (signals error
        (stringify #(1) :number-encoder
          (lambda (number)
            (declare (ignore number))
            (setf seen json-kit::*json-active-aggregates*)
            (error "forced number encoder failure"))))
      (expect (hash-table-p seen) :to-be-truthy)
      (expect (zerop (hash-table-count seen)) :to-be-truthy))))
