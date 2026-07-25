;;;; t/reader-callbacks-test.lisp
(in-package #:cl-json-kit/test)

(describe "user callbacks"
  (it "applies key and number decoders"
    (let ((value (parse "{\"Foo\":12,\"n\":1.5}"
                        :key-decoder (lambda (key) (string-downcase key))
                        :number-decoder (lambda (token integer-p) (list token integer-p)))))
      (expect (gethash "foo" value) :to-equal (list "12" t))
      (expect (gethash "n" value) :to-equal (list "1.5" nil)))
    (expect (parse "1e10001"
                   :max-exact-exponent 1
                   :number-decoder (lambda (token integer-p)
                                     (list token integer-p)))
            :to-equal
            (list "1e10001" nil)))

  (it "applies object and array hooks"
    (expect (parse "[1,2]" :array-type :list :array-hook #'reverse) :to-equal (list 2 1))
    (expect (= (parse "{\"a\":1}" :object-hook (lambda (object) (gethash "a" object))) 1)
            :to-be-truthy))

  (it "passes exact hybrid-boundary vectors once through ARRAY-HOOK"
    (dolist (count (list 256 257 512 513))
      (let* ((expected (coerce (loop for index below count collect index)
                               (quote simple-vector)))
             (input (format nil "[~{~D~^,~}]"
                            (coerce expected (quote list))))
             (calls 0)
             (received nil)
             (hook-result (list :hook-result count))
             (result (parse input
                            :array-hook
                            (lambda (array)
                              (incf calls)
                              (setf received array)
                              hook-result))))
        (expect (= calls 1) :to-be-truthy)
        (expect (typep received (quote simple-vector)) :to-be-truthy)
        (expect received :to-equalp expected)
        (expect (eq result hook-result) :to-be-truthy))))

  (it "requires KEY-DECODER to return a string, blaming the key path"
    (let ((condition
            (capture-json-parse-error
             (parse "{\"key\":1}" :key-decoder (lambda (k) (declare (ignore k)) 42)))))
      (expect (json-parse-error-path condition) :to-equal (list "key"))
      (expect (search "KEY-DECODER" (json-parse-error-expected condition)) :to-be-truthy)))

  (it-each (("{\"key\":1}" :key-decoder "key")
            ("{\"number\":1}" :number-decoder "number")
            ("{\"object\":{}}" :object-hook "object")
            ("{\"array\":[]}" :array-hook "array"))
      "normalizes a throwing ~S callback into a located parse error"
      (text option path-component)
    (let* ((thrower (lambda (&rest args) (declare (ignore args)) (error "boom ~A" path-component)))
           (condition (capture-json-parse-error (parse text option thrower))))
      (expect condition :to-be-type-of 'json-parse-error)
      (expect (json-parse-error-path condition) :to-equal (list path-component))
      (expect (search "boom" (json-parse-error-expected condition)) :to-be-truthy)))

  (it "passes an existing JSON parse error through a callback unchanged"
    (let* ((original (make-condition 'json-parse-error
                                     :position 7 :line 1 :column 8 :path (list "original")
                                     :expected "original callback error" :context "test" :text ""))
           (caught (capture-json-parse-error
                    (parse "1" :number-decoder
                           (lambda (token integer-p)
                             (declare (ignore token integer-p))
                             (error original))))))
      (expect (eq caught original) :to-be-truthy)))

  (it "accepts fbound symbols as callback designators"
    (expect (= (gethash "key" (parse "{\"KEY\":1}" :key-decoder 'string-downcase)) 1)
            :to-be-truthy)
    (expect (parse "2" :number-decoder 'symbol-number-decoder) :to-equal "number:2")
    (expect (= (parse "{\"a\":1}" :object-hook 'hash-table-count) 1) :to-be-truthy)
    (expect (parse "[1,2]" :array-hook 'reverse) :to-equalp #(2 1)))

  (it "blames the deep path when a number decoder throws inside a nested array"
    (let ((condition
            (capture-json-parse-error
             (parse "[[0],[1,2]]"
                    :number-decoder (lambda (token integer-p)
                                      (declare (ignore integer-p))
                                      (when (string= token "2") (error "nested number boom"))
                                      (parse-integer token))))))
      (expect (json-parse-error-path condition) :to-equal (list 1 1))
      (expect (search "nested number boom" (json-parse-error-expected condition)) :to-be-truthy))))
