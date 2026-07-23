;;;; t/writer-test.lisp
(in-package #:cl-json-kit/test)

(progn
  (it
  "stringifies basic scalar types"
  (expect (string= (stringify "hello") "\"hello\"") :to-be-truthy)
  (expect (string= (stringify 42) "42") :to-be-truthy)
  (expect (string= (stringify t) "true") :to-be-truthy)
  (expect (string= (stringify +json-false+) "false") :to-be-truthy)
  (expect (string= (stringify +json-null+) "null") :to-be-truthy)
  (expect (string= (stringify nil) "[]") :to-be-truthy)
  (expect (string= (stringify (parse "false")) "false") :to-be-truthy)
  (expect (string= (stringify (parse "null")) "null") :to-be-truthy))
  (it
    "writes JSON directly to a stream and returns the value"
    (let ((value #(1 2))
          (stream (make-string-output-stream)))
      (expect (eq (write-json value stream) value) :to-be-truthy)
      (expect (string= (get-output-stream-string stream) "[1,2]") :to-be-truthy)))
  (it
    "sorts object keys deterministically"
    (let ((table (make-hash-table :test (function equal))))
      (setf (gethash "z" table) 1
            (gethash "a" table) 2)
      (expect
        (string= (stringify table :sort-keys t) "{\"a\":2,\"z\":1}")
        :to-be-truthy)
      (expect
        (string=
          (stringify table :sort-keys t :pretty t)
          (format nil "{~%  \"a\": 2,~%  \"z\": 1~%}"))
        :to-be-truthy)))
  (it "supports custom markers and validated number encoders"
  (let ((null-marker (list :null))
        (false-marker (list :false)))
    (expect
      (string=
        (stringify (vector null-marker false-marker)
                   :null-value null-marker
                   :false-value false-marker)
        "[null,false]")
      :to-be-truthy))
  (expect
    (string=
      (stringify 12 :number-encoder (lambda (number)
                                      (declare (ignore number))
                                      "1.2e+3"))
      "1.2e+3")
    :to-be-truthy)
  (signals
    json-serialization-error
    (stringify 12 :number-encoder (lambda (number)
                                    (declare (ignore number))
                                    "01")))
  (dolist (code (list #xFF11 #x0661 #x0967))
    (let ((digit (code-char code)))
      (when digit
        (signals
          json-serialization-error
          (stringify 12 :number-encoder (lambda (number)
                                          (declare (ignore number))
                                          (string digit))))))))
  (it
    "enforces exact and plus-one stream output boundaries"
    (let ((stream (make-string-output-stream)))
      (write-json "a" stream :max-output-chars 3)
      (expect (string= (get-output-stream-string stream) "\"a\"") :to-be-truthy))
    (signals
      json-serialization-error
      (write-json "a" (make-string-output-stream) :max-output-chars 2))
    (expect (string= (stringify #() :max-elements 0) "[]") :to-be-truthy)
    (signals json-serialization-error (stringify #(1) :max-elements 0))))

(it
  "stringifies a hash-table as a JSON object"
  (let ((table (make-hash-table :test #'equal)))
    (setf (gethash "a" table) 1)
    (expect (string= (stringify table) "{\"a\":1}") :to-be-truthy)))

(it
  "stringifies a vector as a JSON array, including nested vectors"
  (expect (string= (stringify #(1 2 #(3 4))) "[1,2,[3,4]]") :to-be-truthy))

(it
  "stringifies a plain proper list as a JSON array"
  (expect (string= (stringify (list 1 2 3)) "[1,2,3]") :to-be-truthy)
  (expect (string= (stringify (list "a" "b")) "[\"a\",\"b\"]") :to-be-truthy))

;;; Regression: the whole point of this library.  A list of conses must
;;; never be reinterpreted as an alist/object by inspecting its shape -- it
;;; is written as an array of arrays, exactly like any other list-of-lists,
;;; because STRINGIFY dispatches purely on Lisp type (LIST => array), not on
;;; whether the elements happen to be (KEY . VALUE) pairs.
(it
  "serializes nested proper lists without guessing object intent"
  (expect
    (string= (stringify (list (list 1 2) (list 3 4))) "[[1,2],[3,4]]")
    :to-be-truthy)
  (signals json-serialization-error (stringify (cons 1 2))))

(it
  "requires an explicit alist->json-object wrapper to write an alist as an object"
  (let* ((alist (list (cons "a" 1) (cons "b" 2)))
         (json (stringify (alist->json-object alist))))
    (expect (and (search "\"a\":1" json) (search "\"b\":2" json)) :to-be-truthy)
    (expect
      (and (char= (char json 0) #\{) (char= (char json (1- (length json))) #\}))
      :to-be-truthy)))

(it
  "round-trips hash-table objects through json-object->alist"
  (let ((table (make-hash-table :test #'equal)))
    (setf (gethash "a" table) 1)
    (setf (gethash "b" table) 2)
    (let ((alist (json-object->alist table)))
      (expect (= (cdr (assoc "a" alist :test #'string=)) 1) :to-be-truthy)
      (expect (= (cdr (assoc "b" alist :test #'string=)) 2) :to-be-truthy))))

(it
  "escapes quotes, backslashes, and control characters in strings"
  (let ((input
        (concatenate 'string "a\"b\\c" (string #\Newline) "d" (string #\Tab) "e")))
    (expect (string= (stringify input) "\"a\\\"b\\\\c\\nd\\te\"") :to-be-truthy))
  (expect
    (string= (stringify (string (code-char #x01))) "\"\\u0001\"")
    :to-be-truthy))

(it
  "produces indented output when pretty is true"
  (let ((table (make-hash-table :test #'equal)))
    (setf (gethash "a" table) 1)
    (expect
      (string= (stringify table :pretty t) (format nil "{~%  \"a\": 1~%}"))
      :to-be-truthy)
    (expect
      (string= (stringify (list 1 2) :pretty t) (format nil "[~%  1,~%  2~%]"))
      :to-be-truthy)))

(progn
  (it
    "round-trips parse and stringify for a nested value"
    (let* ((original "{\"name\":\"a\",\"nums\":[1,2,3],\"ok\":true}")
           (value (parse original :object-type :alist :array-type :list :key-type :string))
           (again (stringify (alist->json-object value))))
      (expect
        (string= (stringify (cdr (assoc "nums" value :test #'string=))) "[1,2,3]")
        :to-be-truthy)
      (expect (search "\"name\":\"a\"" again) :to-be-truthy)
      (expect
        (equalp (parse (stringify (parse original))) (parse original))
        :to-be-truthy)))
  (it
    "rejects circular aggregate values but permits shared subtrees"
    (let ((list (list 1)))
      (setf (cdr list) list)
      (signals json-serialization-error (stringify list)))
    (let ((vector (vector nil)))
      (setf (aref vector 0) vector)
      (signals json-serialization-error (stringify vector)))
    (let ((table (make-hash-table :test #'equal)))
      (setf (gethash "self" table) table)
      (signals json-serialization-error (stringify table)))
    (let ((child (vector 1)))
      (expect (string= (stringify (vector child child)) "[[1],[1]]") :to-be-truthy)))
  (progn
    (it
  "rejects circular alists during conversion"
  (let ((alist (list (cons "a" 1))))
    (setf (cdr alist) alist)
    (signals json-serialization-error (alist->json-object alist)))
  (let* ((first (list (cons "a" 1)))
         (second (list (cons "b" 2))))
    (setf (cdr first) second
          (cdr second) first)
    (signals json-serialization-error (alist->json-object first))))
    (it "validates conversion shape, key type, and element boundaries"
  (expect
    (= (hash-table-count (alist->json-object (quote ()) :max-elements 0)) 0)
    :to-be-truthy)
  (expect
    (= (gethash "a" (alist->json-object (list (cons "a" 1)) :max-elements 1)) 1)
    :to-be-truthy)
  (signals json-serialization-error
    (alist->json-object (list (cons "a" 1)) :max-elements 0))
  (signals json-serialization-error
    (alist->json-object (cons (cons "a" 1) 2)))
  (signals json-serialization-error
    (alist->json-object (list "malformed")))
  (signals json-serialization-error
    (alist->json-object (list "~A")))
  (signals json-serialization-error
    (alist->json-object (list (cons 1 "non-string key"))))
  (signals json-serialization-error
    (alist->json-object (quote ()) :duplicate-key-policy "~A"))
  (let ((key (list :key)))
    (setf (cdr key) key)
    (signals json-serialization-error
      (alist->json-object (list (cons key 1)))))
  (signals json-serialization-error
    (alist->json-object (quote ()) :max-elements (- (ash 1 100000)))))
    (progn
  (it "applies explicit duplicate key policies"
    (let ((duplicates (list (cons "same" 1) (cons "same" 2))))
      (signals json-serialization-error (alist->json-object duplicates))
      (expect (= (gethash "same" (alist->json-object duplicates :duplicate-key-policy :first)) 1) :to-be-truthy)
      (expect (= (gethash "same" (alist->json-object duplicates :duplicate-key-policy :last)) 2) :to-be-truthy)
      (signals json-serialization-error
        (alist->json-object duplicates :duplicate-key-policy :unknown))))
  (it "preserves ordered and duplicate object members"
  (let* ((members (list (cons "same" 1) (cons "other" 2) (cons "same" 3)))
         (object (alist->json-object members :duplicate-key-policy :preserve))
         (exposed-members (json-object-members object)))
    (expect (json-object-p object) :to-be-truthy)
    (expect (equal (json-object->alist object) members) :to-be-truthy)
    (setf (cdr (first exposed-members)) 99)
    (expect (equal (json-object->alist object) members) :to-be-truthy)
    (expect (string= (stringify object) "{\"same\":1,\"other\":2,\"same\":3}") :to-be-truthy)
    (expect (string= (stringify object :sort-keys t) "{\"same\":1,\"other\":2,\"same\":3}") :to-be-truthy)
    (expect (string= (stringify object :pretty t :indent 2)
                     (format nil "{~%  \"same\": 1,~%  \"other\": 2,~%  \"same\": 3~%}"))
            :to-be-truthy)))
  (it "enforces ordered object serialization boundaries"
    (signals json-serialization-error
      (stringify (make-json-object (list (cons "a" 1) (cons "b" 2))) :max-elements 1))
    (signals json-serialization-error
      (stringify (make-json-object (list (cons "a" "long"))) :max-output-length 5))
    (signals json-serialization-error
      (stringify (make-json-object (list (cons "nested" (vector 1)))) :max-depth 0))
    (let* ((object (make-json-object (list (cons "self" nil))))
       (member (first (json-object-members object))))
  (setf (cdr member) object)
  (expect (string= (stringify object) "{\"self\":[]}") :to-be-truthy))))
    (it
  "bounds and validates object conversion before enumeration"
  (let ((table (make-hash-table :test (function equal))))
    (setf (gethash "a" table) 1)
    (signals json-serialization-error (json-object->alist table :max-elements 0))
    (expect
      (=
        (cdr
          (assoc "a" (json-object->alist table :max-elements 1)
                 :test (function string=)))
        1)
      :to-be-truthy))
  (let ((table (make-hash-table :test (function equal))))
    (setf (gethash 1 table) "bad")
    (signals json-serialization-error (json-object->alist table)))
  (let ((table
          (alist->json-object (list (cons "a" 1))
                              :max-elements most-positive-fixnum)))
    (expect (= (hash-table-count table) 1) :to-be-truthy))))
  (it
    "rejects raw surrogate characters and unsupported numbers"
    (let ((surrogate (code-char #xd800)))
      (when surrogate
        (signals json-serialization-error (stringify (string surrogate)))))
    (signals json-serialization-error (stringify 1/3))
    #+sbcl
    (sb-int:with-float-traps-masked (:invalid :divide-by-zero :overflow)
      (let ((zero 0d0)
            (one 1d0))
        (signals json-serialization-error (stringify (/ zero zero)))
        (signals json-serialization-error (stringify (/ one zero))))))
  (it
    "enforces writer resource limits and indent validation"
    (signals json-serialization-error (stringify "abc" :max-output-length 4))
    (signals json-serialization-error (stringify #(1 2) :max-elements 1))
    (signals json-serialization-error (stringify #(#(1)) :max-depth 0))
    (signals json-serialization-error (stringify #(1) :indent -1))
    (signals json-serialization-error (stringify #(1) :indent 1.5)))
  (it
    "requires unique string hash-table keys"
    (let ((table (make-hash-table :test #'eq)))
      (setf (gethash 1 table) "bad")
      (signals json-serialization-error (stringify table)))
    (let* ((table (make-hash-table :test #'eq))
           (first (copy-seq "same"))
           (second (copy-seq "same")))
      (setf (gethash first table) 1)
      (setf (gethash second table) 2)
      (signals json-serialization-error (stringify table))))
  (it
    "emits finite floats as JSON numbers with exact round trips"
    (dolist (value
        (list
          1.5d0
          -2.25f0
          0.0f0
          -0.0f0
          0.0d0
          -0.0d0
          least-positive-normalized-single-float
          most-positive-single-float
          least-positive-normalized-double-float
          most-positive-double-float
          (float 16777215 1.0f0)
          (float 9007199254740991 1.0d0)))
      (let* ((text (json-kit::json-float-string value))
             (*read-default-float-format* (type-of value)))
        (expect
          (null
            (find-if
              (lambda (character)
                (find character "dDfFsSlL" :test (function char=)))
              text))
          :to-be-truthy)
        (expect (numberp (parse text)) :to-be-truthy)
        (multiple-value-bind (roundtrip end) (read-from-string text)
          (expect (= end (length text)) :to-be-truthy)
          (expect (typep roundtrip (type-of value)) :to-be-truthy)
          (expect (= roundtrip value) :to-be-truthy)
          (when (zerop value)
            (expect (= (float-sign roundtrip) (float-sign value)) :to-be-truthy)))))))

(it
  "writes exact terminating ratios and preserves negative zero"
  (expect (string= (stringify (/ 1 2)) "0.5") :to-be-truthy)
  (expect (string= (stringify (/ -1 40)) "-0.025") :to-be-truthy)
  (expect (string= (stringify (/ 123 25)) "4.92") :to-be-truthy)
  (expect (string= (stringify -0.0d0) "-0.0") :to-be-truthy)
  (signals json-serialization-error (stringify (/ 1 3)))
  (expect (string= (stringify (/ 1 3) :number-encoder (lambda (number) (declare (ignore number)) "0.333")) "0.333") :to-be-truthy))

(progn
  (it "validates output stream designators before serialization"
    (let ((*standard-output* (make-string-output-stream)))
      (expect (eql (write-json 1 nil) 1) :to-be-truthy)
      (expect (string= (get-output-stream-string *standard-output*) "1")
              :to-be-truthy))
    (signals json-serialization-error (write-json 1 42))
    (let ((stream (make-string-input-stream "")))
      (unwind-protect
           (signals json-serialization-error (write-json 1 stream))
        (close stream)))
    (let ((stream (make-string-output-stream)))
      (close stream)
      (signals json-serialization-error (write-json 1 stream)))
    (let ((pathname
            (make-pathname
              :name (format nil "cl-json-kit-~A" (gensym))
              :type "bin"
              :defaults (uiop:temporary-directory))))
      (unwind-protect
           (with-open-file (stream pathname
                                   :direction :output
                                   :element-type (quote (unsigned-byte 8))
                                   :if-exists :supersede
                                   :if-does-not-exist :create)
             (signals json-serialization-error (write-json 1 stream)))
        (when (probe-file pathname)
          (delete-file pathname)))))

  (it "preserves output length alias compatibility"
    (expect (string= (stringify "a"
                                :max-output-chars 3
                                :max-output-length 3)
                     "\"a\"")
            :to-be-truthy)
    (signals json-serialization-error
      (stringify "a" :max-output-chars 3 :max-output-length 4)))

  (it "bounds terminating ratios before expensive conversion"
    (let ((value (/ 1 (expt 2 8))))
      (expect (string= (stringify value :max-output-length 10) "0.00390625")
              :to-be-truthy)
      (signals json-serialization-error
        (stringify value :max-output-length 9)))
    (let ((huge-value (/ 1 (expt 2 128))))
      (signals json-serialization-error
        (stringify huge-value :max-output-length 32))
      (expect (string= (stringify huge-value
                                  :max-output-length 1
                                  :number-encoder
                                  (lambda (number)
                                    (declare (ignore number))
                                    "0"))
                       "0")
              :to-be-truthy))
    (signals json-serialization-error
      (stringify (/ (1+ (ash 1 128))
                    (ash 1 128))
                 :max-output-length 32)))

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
    (expect (string= (stringify (list 1 2 3) :max-elements 3) "[1,2,3]")
            :to-be-truthy)
    (signals json-serialization-error
      (stringify (list 1 2 3) :max-elements 2)))

  (it "serializes a large unsorted object directly from its hash table"
    (let ((table (make-hash-table :test (function equal))))
      (loop for index below 10000
            do (setf (gethash (format nil "key-~D" index) table) index))
      (let ((decoded (parse (stringify table :sort-keys nil))))
        (expect (= (hash-table-count decoded) 10000) :to-be-truthy)
        (expect (= (gethash "key-0" decoded) 0) :to-be-truthy)
        (expect (= (gethash "key-9999" decoded) 9999) :to-be-truthy)))))
