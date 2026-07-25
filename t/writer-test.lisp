;;;; t/writer-test.lisp
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

(describe "string escaping"
  (it "escapes quotes, backslashes, solidus-free text, and control characters"
    (let ((input (concatenate 'string "a\"b\\c" (string #\Newline) "d" (string #\Tab) "e")))
      (expect input :to-stringify-as "\"a\\\"b\\\\c\\nd\\te\""))
    (expect (string (code-char #x01)) :to-stringify-as "\"\\u0001\""))

  (it "escapes correctly across plain-run boundaries"
    ;; Escapes at the start, end, and interior of a plain run must all survive
    ;; the run-flushing encode path unchanged.
    (dolist (case (list (cons "plain" "\"plain\"")
                        (cons "\"plain" "\"\\\"plain\"")
                        (cons "plain\"" "\"plain\\\"\"")
                        (cons "a\"b\\c" "\"a\\\"b\\\\c\"")
                        (cons (concatenate 'string "ab" (string #\Newline) "cd"
                                           (string #\Tab) "ef")
                              "\"ab\\ncd\\tef\"")))
      (expect (string= (stringify (car case)) (cdr case)) :to-be-truthy)))

  (it "truncates escaped output at exact character boundaries"
    ;; ab"cd escapes to "ab\"cd" (8 characters); each budget must stop the
    ;; stream at the same byte the char-accurate writer would.
    (let ((input "ab\"cd"))
      (expect (string= (stringify input :max-output-length 8) "\"ab\\\"cd\"") :to-be-truthy)
      (signals json-serialization-error (stringify input :max-output-length 7))
      (dolist (case (list (cons 4 "\"ab")
                          (cons 5 "\"ab\\\"")
                          (cons 7 "\"ab\\\"cd")))
        (let ((stream (make-string-output-stream)))
          (handler-case (write-json input stream :max-output-length (car case))
            (json-serialization-error ()))
          (expect (string= (get-output-stream-string stream) (cdr case)) :to-be-truthy)))))

  (it "rejects raw surrogate characters"
    (let ((surrogate (code-char #xd800)))
      (when surrogate
        (signals json-serialization-error (stringify (string surrogate)))
        (signals json-serialization-error
          (stringify (concatenate 'string "plain" (string surrogate) "tail"))))))

  (it "accounts dense escaped output at exact maximum-length boundaries"
    (let* ((unit (concatenate 'string "\"" "\\"
                              (string (code-char #x00))
                              (string (code-char #x1f))
                              "ab"))
           (input (with-output-to-string (stream)
                    (loop repeat 24
                          do (write-string unit stream))
                    (write-string "tail" stream)))
           (expected (with-output-to-string (stream)
                       (write-char #\" stream)
                       (loop repeat 24
                             do (write-string "\\\"" stream)
                                (write-string "\\\\" stream)
                                (write-string "\\u0000" stream)
                                (write-string "\\u001F" stream)
                                (write-string "ab" stream))
                       (write-string "tail\"" stream)))
           (exact-length (length expected)))
      (progn
        (expect (= (length input) 148) :to-be-truthy)
        (dolist (size (list 4095 4096 8193))
          (let* ((dense-input (make-string size :initial-element #\"))
                 (dense-expected
                   (with-output-to-string (stream)
                     (write-char #\" stream)
                     (loop repeat size do (write-string "\\\"" stream))
                     (write-char #\" stream))))
            (expect (stringify dense-input) :to-equal dense-expected)))
        (let* ((late-input
                 (concatenate (quote string)
                              (make-string 12 :initial-element #\")
                              (make-string 8168 :initial-element #\a)
                              "\"\\"
                              (string (code-char #x00))))
               (late-expected
                 (with-output-to-string (stream)
                   (write-char #\" stream)
                   (loop repeat 12 do (write-string "\\\"" stream))
                   (loop repeat 8168 do (write-char #\a stream))
                   (write-string "\\\"" stream)
                   (write-string "\\\\" stream)
                   (write-string "\\u0000" stream)
                   (write-char #\" stream))))
          (expect (stringify late-input) :to-equal late-expected)))
      (expect (>= (loop for index below 128
                        for character = (char input index)
                        count (or (char= character #\")
                                  (char= character #\\)))
                  12)
              :to-be-truthy)
      (dolist (case (list (cons (1- exact-length) t)
                          (cons exact-length nil)
                          (cons (1+ exact-length) nil)))
        (let ((stream (make-string-output-stream))
              (signalled nil)
              (json-kit::*json-output-count* 0)
              (json-kit::*json-maximum-output-length* (car case)))
          (let ((json-kit::*json-output-stream* stream))
            (handler-case (json-kit::write-json-string input)
              (json-serialization-error ()
                (setf signalled t))))
          (let ((output (get-output-stream-string stream)))
            (expect (eq signalled (cdr case)) :to-be-truthy)
            (expect (string= output
                             (if (cdr case)
                                 (subseq expected 0 (car case))
                                 expected))
                    :to-be-truthy)
            (expect (= json-kit::*json-output-count* (length output))
                    :to-be-truthy)))))))

(describe "bounded dense string escaping"
  (it "keeps quote and backslash escapes atomic"
    (dolist (escape (list #\" #\\))
      (let ((input (make-string 128 :initial-element #\a))
            (stream (make-string-output-stream)))
        (fill input escape :end 12)
        (signals json-serialization-error
          (write-json input stream :max-output-length 2))
        (expect (string= (get-output-stream-string stream) (string #\"))
                :to-be-truthy)))))

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

  (it "rejects a non-integer or negative MAX-DEPTH, MAX-ELEMENTS, or MAX-OUTPUT-LENGTH"
    (signals json-serialization-error (stringify #(1) :max-depth -1))
    (signals json-serialization-error (stringify #(1) :max-depth 1.5))
    (signals json-serialization-error (stringify #(1) :max-elements -1))
    (signals json-serialization-error (stringify #(1) :max-elements 1.5))
    (signals json-serialization-error (stringify #(1) :max-output-length -1))
    (signals json-serialization-error (stringify #(1) :max-output-length 1.5)))

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

(describe "output stream designators"
  (it "writes to a stream and returns the value"
    (let ((value #(1 2))
          (stream (make-string-output-stream)))
      (expect (eq (write-json value stream) value) :to-be-truthy)
      (expect (string= (get-output-stream-string stream) "[1,2]") :to-be-truthy)))

  (it "resolves and validates the STREAM argument"
    (let ((*standard-output* (make-string-output-stream)))
      (expect (eql (write-json 1 nil) 1) :to-be-truthy)
      (expect (string= (get-output-stream-string *standard-output*) "1") :to-be-truthy))
    (signals json-serialization-error (write-json 1 42))
    (let ((stream (make-string-input-stream "")))
      (unwind-protect (signals json-serialization-error (write-json 1 stream))
        (close stream)))
    (let ((stream (make-string-output-stream)))
      (close stream)
      (signals json-serialization-error (write-json 1 stream)))
    (let ((pathname (make-pathname :name (format nil "cl-json-kit-~A" (gensym)) :type "bin"
                                   :defaults (uiop:temporary-directory))))
      (unwind-protect
           (with-open-file (stream pathname :direction :output :element-type '(unsigned-byte 8)
                                            :if-exists :supersede :if-does-not-exist :create)
             (signals json-serialization-error (write-json 1 stream)))
        (when (probe-file pathname) (delete-file pathname))))))

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
    (expect (= (gethash "a" (alist->json-object (list (cons "a" 1)) :max-elements 1)) 1) :to-be-truthy)
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
