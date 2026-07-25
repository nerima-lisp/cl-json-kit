;;;; t/reader-collections-test.lisp
(in-package #:cl-json-kit/test)

(describe "collections and duplicate keys"
  (it "selects representation from :OBJECT-TYPE and :ARRAY-TYPE"
    (expect "[1,[2]]" :to-parse-as #(1 #(2)))
    (expect (parse "[1,[2]]" :array-type :list) :to-equal (list 1 (list 2)))
    (expect (parse "{\"x\":1}" :object-type :alist) :to-equal (list (cons "x" 1)))
    (dolist (count (list 0 1 8 255 256 257 512 513 1024 100000))
      (let* ((expected (loop for index below count collect index))
             (input (with-output-to-string (stream)
                      (write-char #\[ stream)
                      (loop for index below count
                            do (when (plusp index)
                                 (write-char #\, stream))
                               (princ index stream))
                      (write-char #\] stream)))
             (vector (parse input :array-type :vector))
             (list-value (parse input :array-type :list)))
        (expect (typep vector (quote simple-vector)) :to-be-truthy)
        (expect (length vector) :to-equal count)
        (expect (coerce vector (quote list)) :to-equal expected)
        (expect list-value :to-equal expected))))

  (it-each ((:first 1) (:last 2))
      "resolves duplicate keys under policy ~S"
      (policy expected)
    (expect (= (gethash "a" (parse "{\"a\":1,\"a\":2}" :duplicate-key-policy policy))
               expected)
            :to-be-truthy))

  (it "preserves ordered duplicates and decoded-key collisions under :PRESERVE with an alist"
    (expect (parse "{\"a\":1,\"a\":2}"
                   :object-type :alist
                   :duplicate-key-policy :preserve)
            :to-equal (list (cons "a" 1) (cons "a" 2)))
    (let ((calls 0))
      (expect (parse "{\"A\":1,\"a\":2}"
                     :object-type :alist
                     :duplicate-key-policy :preserve
                     :key-decoder (lambda (key)
                                    (incf calls)
                                    (string-downcase key)))
              :to-equal (list (cons "a" 1) (cons "a" 2)))
      (expect (= calls 2) :to-be-truthy)))

  (it "reports the offending key when :ERROR meets a duplicate"
    (let ((condition
            (capture-json-parse-error (parse "{\"a\":1,\"a\":2}" :duplicate-key-policy :error))))
      (expect condition :to-be-type-of 'json-parse-error)
      (expect (json-parse-error-path condition) :to-equal (list "a"))))

  (it "folds decoded keys before applying the duplicate policy"
    (let ((decoder (lambda (key) (string-downcase key))))
      (signals json-parse-error
        (parse "{\"A\":1,\"a\":2}" :key-decoder decoder :duplicate-key-policy :error))
      (let ((first (parse "{\"A\":1,\"a\":2}" :key-decoder decoder :duplicate-key-policy :first))
            (last (parse "{\"A\":1,\"a\":2}" :key-decoder decoder :duplicate-key-policy :last)))
        (expect (= (hash-table-count first) 1) :to-be-truthy)
        (expect (= (gethash "a" first) 1) :to-be-truthy)
        (expect (= (gethash "a" last) 2) :to-be-truthy))))

  (it "stops at the first duplicate before decoding the second value"
    (let ((calls 0))
      (signals json-parse-error
        (parse "{\"a\":1,\"A\":2}"
               :key-decoder #'string-downcase
               :duplicate-key-policy :error
               :number-decoder (lambda (token integer-p)
                                 (declare (ignore integer-p))
                                 (incf calls)
                                 (parse-integer token))))
      (expect (= calls 1) :to-be-truthy)))

  (it "round-trips duplicate members through the explicit representation"
    (let* ((text "{\"a\":1,\"a\":2}")
           (members (parse text :object-type :alist :duplicate-key-policy :preserve)))
      (expect (alist->json-object members :duplicate-key-policy :preserve)
              :to-stringify-as text)))

  (it-each ((:preserve :hash-table) (:invalid :hash-table))
      "rejects duplicate-key policy ~S with object-type ~S"
      (policy object-type)
    (signals json-parse-error
      (parse "{}" :object-type object-type :duplicate-key-policy policy)))

  (it-each ((:object-type :invalid) (:array-type :invalid))
      "rejects invalid option ~S ~S"
      (option value)
    (signals json-parse-error (parse "{}" option value)))

  (it-each ((:first 1) (:last 2))
      "resolves duplicate alist keys under policy ~S"
      (policy expected)
    (let ((alist (parse "{\"a\":1,\"a\":2}" :object-type :alist :duplicate-key-policy policy)))
      (expect alist :to-equal (list (cons "a" expected)))))

  (it "keeps distinct alist keys under :FIRST and :LAST"
    (expect (parse "{\"a\":1,\"b\":2}" :object-type :alist :duplicate-key-policy :first)
            :to-equal (list (cons "a" 1) (cons "b" 2)))
    (expect (parse "{\"a\":1,\"b\":2}" :object-type :alist :duplicate-key-policy :last)
            :to-equal (list (cons "a" 1) (cons "b" 2))))

  (it "keeps present-vs-absent distinct for NIL values and still decodes dropped duplicates"
    ;; With :NULL-VALUE NIL, presence must be tracked independently of the value,
    ;; and a dropped duplicate's value is still decoded before being discarded.
    (let ((first (parse "{\"a\":null,\"a\":1}" :null-value nil :duplicate-key-policy :first))
          (last (parse "{\"a\":null,\"a\":1}" :null-value nil :duplicate-key-policy :last)))
      (multiple-value-bind (value present-p) (gethash "a" first)
        (expect (null value) :to-be-truthy)
        (expect present-p :to-be-truthy))
      (expect (= (gethash "a" last) 1) :to-be-truthy))
    (expect (parse "{\"a\":null,\"a\":1}" :null-value nil
                                          :object-type :alist :duplicate-key-policy :first)
            :to-equal (list (cons "a" nil)))
    (expect (parse "{\"a\":null,\"a\":1}" :null-value nil
                                          :object-type :alist :duplicate-key-policy :last)
            :to-equal (list (cons "a" 1)))
    (let ((calls 0))
      (let ((object (parse "{\"a\":1,\"A\":2}"
                           :key-decoder #'string-downcase
                           :duplicate-key-policy :first
                           :number-decoder (lambda (token integer-p)
                                             (declare (ignore integer-p))
                                             (incf calls)
                                             (parse-integer token)))))
        (expect (= calls 2) :to-be-truthy)
        (expect (= (gethash "a" object) 1) :to-be-truthy))))

  (it "parses mixed RFC whitespace in vector and list arrays"
    (let ((text (format nil "[~C1~C,~C2~C]"
                        (code-char #x09)
                        (code-char #x0D)
                        (code-char #x0A)
                        (code-char #x20))))
      (let ((vector (parse text :array-type :vector))
            (list-value (parse text :array-type :list)))
        (expect (typep vector (quote simple-vector)) :to-be-truthy)
        (expect (coerce vector (quote list)) :to-equal (list 1 2))
        (expect list-value :to-equal (list 1 2)))))

  (it "parses mixed RFC whitespace through every generic alist policy"
    (let ((text (format nil "{~C\"a\"~C:~C1~C,~C\"b\"~C:~C2~C}"
                        (code-char #x09)
                        (code-char #x20)
                        (code-char #x0D)
                        (code-char #x0A)
                        (code-char #x09)
                        (code-char #x0D)
                        (code-char #x20)
                        (code-char #x0A)))
          (expected (list (cons "a" 1) (cons "b" 2))))
      (dolist (policy (list :first :last :preserve :error))
        (expect (parse text :object-type :alist :duplicate-key-policy policy)
                :to-equal expected))))

  (it-each (("{\"a\":1,}") ("{\"a\":1 2}") ("[1,]") ("[1 2]") ("{\"a\":{}}"))
      "rejects the malformed structure ~S"
      (text)
    (signals json-parse-error (parse text :max-depth 1))))

(describe "large objects"
  ;; A four-thousand-member object exercises the object accumulator well past
  ;; any incremental-growth boundary, confirming the result, the resource
  ;; bounds, and the callback firing order are all independent of object size.
  (it "parses a large object across trailing suffixes and enforces its bounds"
    (let* ((member-count 4096)
           (object-text
             (with-output-to-string (stream)
               (write-char #\{ stream)
               (dotimes (index member-count)
                 (unless (zerop index) (write-char #\, stream))
                 (format stream "\"k~D\":~D" index index))
               (write-char #\} stream))))
      ;; Final contents are correct regardless of trailing whitespace.
      (dolist (suffix (list "" " " (string #\Tab) (string #\Newline) (string #\Return)
                            (format nil "~C~C~C~C" #\Space #\Tab #\Newline #\Return)
                            (make-string (* 1024 1024) :initial-element #\Space)))
        (let ((value (parse (concatenate 'string object-text suffix))))
          (expect (= (hash-table-count value) member-count) :to-be-truthy)
          (expect (= (gethash "k0" value) 0) :to-be-truthy)
          (expect (= (gethash "k4095" value) 4095) :to-be-truthy)))
      ;; A non-whitespace suffix is trailing data at exactly the object's end.
      (let ((condition (capture-json-parse-error (parse (concatenate 'string object-text "x")))))
        (expect (= (json-parse-error-position condition) (length object-text)) :to-be-truthy)
        (expect (json-parse-error-path condition) :to-be-falsy)
        (expect (string= (json-parse-error-expected condition) "end of input") :to-be-truthy))
      ;; The member bound still fires on the large object.
      (let ((condition (capture-json-parse-error
                        (parse object-text :max-object-members (1- member-count)))))
        (expect (json-parse-error-path condition) :to-be-falsy)
        (expect (string= (json-parse-error-expected condition) "fewer object members")
                :to-be-truthy))
      ;; Key/number decoders and the object hook each fire once per member, in order.
      (let ((key-count 0) (number-count 0) (trace nil))
        (let ((value (parse object-text
                            :key-decoder (lambda (key)
                                           (incf key-count)
                                           (when (or (= key-count 1) (= key-count member-count))
                                             (push (list :key key-count key) trace))
                                           key)
                            :number-decoder (lambda (token integer-p)
                                              (incf number-count)
                                              (when (or (= number-count 1)
                                                        (= number-count member-count))
                                                (push (list :number number-count token integer-p)
                                                      trace))
                                              (parse-integer token))
                            :object-hook (lambda (object)
                                           (push (list :object (hash-table-count object)
                                                       (gethash "k4095" object))
                                                 trace)
                                           object))))
          (expect (= key-count member-count) :to-be-truthy)
          (expect (= number-count member-count) :to-be-truthy)
          (expect (nreverse trace)
                  :to-equal (list (list :key 1 "k0")
                                  (list :number 1 "0" t)
                                  (list :key member-count "k4095")
                                  (list :number member-count "4095" t)
                                  (list :object member-count 4095)))
          (expect (= (hash-table-count value) member-count) :to-be-truthy)))
      ;; A throwing object hook is reported at the object's end, with no path.
      (let ((condition (capture-json-parse-error
                        (parse object-text
                               :object-hook (lambda (object)
                                              (declare (ignore object))
                                              (error "boundary hook"))))))
        (expect (= (json-parse-error-position condition) (length object-text)) :to-be-truthy)
        (expect (json-parse-error-path condition) :to-be-falsy)
        (expect (search "OBJECT-HOOK" (json-parse-error-expected condition)) :to-be-truthy)))))
