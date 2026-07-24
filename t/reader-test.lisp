;;;; t/reader-test.lisp
(in-package #:cl-json-kit/test)

(describe "reading scalars"
  (it "parses primitive tokens with opaque null/false defaults"
    (expect "\"hello\"" :to-parse-as "hello")
    (expect "42" :to-parse-as 42)
    (expect (parse "true") :to-be t)
    (expect (parse "false") :to-satisfy #'json-false-p)
    (expect (parse "null") :to-satisfy #'json-null-p)
    (expect (eq +json-null+ +json-false+) :to-be-falsy))

  (it "keeps 1.5 a double-float"
    (expect (parse "1.5") :to-be-type-of 'double-float))

  (it "honours explicit scalar mappings"
    (expect (parse "null" :null-value :missing) :to-be :missing)
    (expect (parse "false" :false-value nil) :to-be nil)
    (expect (parse "true" :true-value :yes) :to-be :yes)))

(describe "number grammar"
  (it-each (("0") ("-0") ("10") ("-12") ("0.5") ("1e2") ("1E-2") ("1e+2"))
      "accepts the JSON number ~S"
      (text)
    (expect (numberp (parse text)) :to-be-truthy))

  (it-each (("01") ("-01") ("+1") (".1") ("1.") ("1e") ("1e+") ("--1"))
      "rejects the malformed number ~S"
      (text)
    (signals json-parse-error (parse text)))

  (it-each ((#xFF11) (#x0661) (#x0967))
      "rejects the non-ASCII digit U+~4,'0X"
      (code)
    (let ((text (format nil "[~C]" (code-char code))))
      (signals json-parse-error (parse text))
      (with-input-from-string (stream text)
        (signals json-parse-error (read-json stream)))))

  (it "represents large and small magnitudes exactly within MAX-EXACT-EXPONENT"
    (let ((large (parse "1e400" :max-exact-exponent 400))
          (small (parse "1e-400" :max-exact-exponent 400))
          (negative-large (parse "-1e400" :max-exact-exponent 400))
          (negative-small (parse "-1e-400" :max-exact-exponent 400)))
      (expect (integerp large) :to-be-truthy)
      (expect (= large (expt 10 400)) :to-be-truthy)
      (expect (rationalp small) :to-be-truthy)
      (expect (= small (/ 1 (expt 10 400))) :to-be-truthy)
      (expect (= negative-large (- (expt 10 400))) :to-be-truthy)
      (expect (= negative-small (- (/ 1 (expt 10 400)))) :to-be-truthy)))

  (it-each (("1e401" 400) ("1e-401" 400) ("1e1000000000" 10000)
            ("1e-1000000000" 10000))
      "rejects the out-of-range scale ~S"
      (text limit)
    (signals json-parse-error (parse text :max-exact-exponent limit)))

  (it "rejects an enormous exponent literal but accepts leading-zero padding"
    (let ((huge (make-string 512 :initial-element #\9))
          (padded (make-string 512 :initial-element #\0)))
      (signals json-parse-error (parse (concatenate 'string "1e" huge)))
      (signals json-parse-error (parse (concatenate 'string "1e-" huge)))
      (expect (= (parse (concatenate 'string "1e" padded "1")) 10.0d0) :to-be-truthy)
      (let ((negative-zero (parse (concatenate 'string "-0e" huge))))
        (expect (zerop negative-zero) :to-be-truthy)
        (expect (= (float-sign negative-zero) -1.0d0) :to-be-truthy))))

  (it "treats zero coefficients with any exponent as signed float zero"
    (let ((positive (parse "0e10001"))
          (negative (parse "-0e10001")))
      (expect positive :to-be-type-of 'double-float)
      (expect (zerop positive) :to-be-truthy)
      (expect negative :to-be-type-of 'double-float)
      (expect (zerop negative) :to-be-truthy)
      (expect (= (float-sign negative) -1.0d0) :to-be-truthy))))

(describe "strings and unicode"
  (it "decodes escapes, including surrogate pairs beyond the BMP"
    (expect (char= (char (parse "\"\\u0041\"") 0) #\A) :to-be-truthy)
    (expect (= (char-code (char (parse "\"\\uD83D\\uDE00\"") 0)) #x1F600) :to-be-truthy))

  (it-each (("\"\\uD800\"") ("\"\\uDC00\"") ("\"\\uD800\\u0041\"") ("\"\\x\""))
      "rejects the invalid string escape ~S"
      (text)
    (signals json-parse-error (parse text)))

  (it "decodes lowercase hex escapes and lowercase surrogate pairs"
    (expect (= (char-code (char (parse "\"\\u00e9\"") 0)) #xE9) :to-be-truthy)
    (expect (= (char-code (char (parse "\"\\ud83d\\ude00\"") 0)) #x1F600) :to-be-truthy))

  (it "enforces MAX-STRING-LENGTH along the escaped slow path"
    (signals json-parse-error (parse "\"a\\n\\n\"" :max-string-length 2)))

  (it "rejects raw control characters in strings"
    (signals json-parse-error (parse (format nil "\"a~Cb\"" (code-char 1)))))

  (it "round-trips every short escape through the shared escape table"
    (let ((decoded (parse "\"\\b\\f\\n\\r\\t\\\"\\\\\\/\""))
          (expected (coerce (list #\Backspace #\Page #\Newline #\Return #\Tab
                                  #\" #\\ #\/)
                            'string)))
      (expect decoded :to-equal expected)))

  (it "bounds decoded escaped-string length exactly and combines escapes beyond the BMP"
    ;; The JSON unit a\"b\\cA decodes to the six characters a"b\cA; repeating
    ;; it drives the escaped slow path over a long, mixed-escape string.
    (let* ((unit "a\\\"b\\\\c\\u0041")
           (encoded (format nil "\"~{~A~}\"" (make-list 128 :initial-element unit)))
           (expected (format nil "~{~A~}" (make-list 128 :initial-element "a\"b\\cA"))))
      (expect (string= (parse encoded :max-string-length (length expected)) expected)
              :to-be-truthy)
      (signals json-parse-error (parse encoded :max-string-length (1- (length expected)))))
    (expect (string= (parse "\"\\uD83D\\uDE00\\\"\\\\\"")
                     (format nil "~C\"\\" (code-char #x1F600)))
            :to-be-truthy)
    (let* ((tail (make-string 10000 :initial-element #\a))
           (value (parse (format nil "[\"\\\"\",\"~A\"]" tail))))
      (expect (string= (aref value 0) "\"") :to-be-truthy)
      (expect (string= (aref value 1) tail) :to-be-truthy))))

(describe "collections and duplicate keys"
  (it "selects representation from :OBJECT-TYPE and :ARRAY-TYPE"
    (expect "[1,[2]]" :to-parse-as #(1 #(2)))
    (expect (parse "[1,[2]]" :array-type :list) :to-equal (list 1 (list 2)))
    (expect (parse "{\"x\":1}" :object-type :alist) :to-equal (list (cons "x" 1))))

  (it-each ((:first 1) (:last 2))
      "resolves duplicate keys under policy ~S"
      (policy expected)
    (expect (= (gethash "a" (parse "{\"a\":1,\"a\":2}" :duplicate-key-policy policy))
               expected)
            :to-be-truthy))

  (it "preserves ordered duplicates only under :PRESERVE with an alist"
    (expect (parse "{\"a\":1,\"a\":2}" :object-type :alist :duplicate-key-policy :preserve)
            :to-equal (list (cons "a" 1) (cons "a" 2))))

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

(describe "resource bounds and truncation"
  (it "honours element, depth, string, and number limits"
    (expect (parse "[]" :max-array-elements 0) :to-equalp #())
    (signals json-parse-error (parse "[0]" :max-array-elements 0))
    (expect (= (hash-table-count (parse "{}" :max-object-members 0)) 0) :to-be-truthy)
    (signals json-parse-error (parse "{\"a\":0}" :max-object-members 0))
    (expect (parse "[]" :max-depth 1) :to-equalp #())
    (signals json-parse-error (parse "[[]]" :max-depth 1))
    (expect "\"a\"" :to-parse-as "a")
    (signals json-parse-error (parse "\"ab\"" :max-string-length 1))
    (expect (= (parse "1" :max-number-length 1) 1) :to-be-truthy)
    (signals json-parse-error (parse "12" :max-number-length 1))
    (signals json-parse-error (parse "null" :max-input-length 3)))

  (it-each (("") ("[") ("[1") ("[1,") ("{") ("{\"a\"") ("{\"a\":")
            ("\"") ("\"\\") ("tru") ("-") ("1e"))
      "rejects the truncated input ~S"
      (text)
    (signals json-parse-error (parse text)))

  (it-each ((:max-depth -1) (:max-array-elements 1.5) (:max-exact-exponent -1))
      "rejects the non-integer resource limit ~S ~S"
      (option value)
    (signals json-parse-error (parse "null" option value)))

  (it "rejects trailing input and non-RFC whitespace"
    (expect (= (parse (format nil "~C~C~C~C1" #\Space #\Tab #\Return #\Newline)) 1)
            :to-be-truthy)
    (signals json-parse-error (parse (format nil "~C1" #\Page)))
    (signals json-parse-error (parse "true false"))
    (signals json-parse-error (parse "[]x"))))

(describe "error reporting"
  (it "reports stable position, line, column, and structured path"
    (let ((condition
            (capture-json-parse-error
             (parse (format nil "{\"outer\": [0,~% nope]}") :context "unit-test"))))
      (expect (= (json-parse-error-position condition) 15) :to-be-truthy)
      (expect (= (json-parse-error-line condition) 2) :to-be-truthy)
      (expect (= (json-parse-error-column condition) 2) :to-be-truthy)
      (expect (json-parse-error-path condition) :to-equal (list "outer" 1))
      (expect (stringp (json-parse-error-expected condition)) :to-be-truthy)
      (expect (string= (json-parse-error-context condition) "unit-test") :to-be-truthy)
      (expect (stringp (json-parse-error-text condition)) :to-be-truthy)))

  (it-each (((#\Return)) ((#\Newline)) ((#\Return #\Newline)))
      "counts the line break ~S as one source line while keeping the path"
      (break-characters)
    (let* ((newline (coerce break-characters 'string))
           (condition
             (capture-json-parse-error (parse (format nil "{\"a\":[0,~A ?]}" newline)))))
      (expect (= (json-parse-error-line condition) 2) :to-be-truthy)
      (expect (= (json-parse-error-column condition) 2) :to-be-truthy)
      (expect (json-parse-error-path condition) :to-equal (list "a" 1))))

  (it "escapes a raw tab and a raw backspace inside the captured error snippet"
    (let ((tab-condition (capture-json-parse-error (parse (format nil "~C]" #\Tab))))
          (backspace-condition (capture-json-parse-error (parse (format nil "~C@" (code-char 8))))))
      (expect (search "\\t" (json-parse-error-text tab-condition)) :to-be-truthy)
      (expect (search "\\b" (json-parse-error-text backspace-condition)) :to-be-truthy)))

  (it "positions the error at the overrun when MAX-STRING-LENGTH is exceeded by an escape"
    (let ((condition (capture-json-parse-error (parse "\"\\u0041\"" :max-string-length 0))))
      (expect (= (json-parse-error-position condition) 7) :to-be-truthy)
      (expect (= (json-parse-error-line condition) 1) :to-be-truthy)
      (expect (= (json-parse-error-column condition) 8) :to-be-truthy)))

  (it "tracks the structured path only while parsing the offending member value"
    (dolist (case (list (list "{\"a\":[{\"b\":[0,?]}]}" (list "a" 0 "b" 1))
                        (list "[[0],[1,?]]" (list 1 1))
                        (list "[[0],?]" (list 1))
                        (list "{\"outer\":{\"bad\\q\":1}}" (list "outer"))
                        (list "{\"outer\":{\"bad\" 1}}" (list "outer"))
                        (list "{\"outer\":[0,]}" (list "outer"))
                        (list "{\"outer\":[0 x]}" (list "outer"))))
      (destructuring-bind (text expected-path) case
        (let ((condition (capture-json-parse-error (parse text))))
          (expect (json-parse-error-path condition) :to-equal expected-path)))))

  (it "reports exact coordinates and diagnostics for array-position errors"
    (dolist (case (list (list (format nil "[0,~% ?]") nil 5 2 2 (list 1) "JSON value")
                        (list "{\"outer\":[0,]}" nil 12 1 13 (list "outer") "array value")
                        (list "[1,2]" (list :max-array-elements 1) 3 1 4 nil "fewer array elements")))
      (destructuring-bind (text options position line column path diagnostic) case
        (let ((condition (capture-json-parse-error
                          (apply #'parse text (list* :context "array-regression" options)))))
          (expect (= (json-parse-error-position condition) position) :to-be-truthy)
          (expect (= (json-parse-error-line condition) line) :to-be-truthy)
          (expect (= (json-parse-error-column condition) column) :to-be-truthy)
          (expect (json-parse-error-path condition) :to-equal path)
          (expect (string= (json-parse-error-expected condition) diagnostic) :to-be-truthy)
          (expect (string= (json-parse-error-context condition) "array-regression")
                  :to-be-truthy))))))

(describe "user callbacks"
  (it "applies key and number decoders"
    (let ((value (parse "{\"Foo\":12,\"n\":1.5}"
                        :key-decoder (lambda (key) (string-downcase key))
                        :number-decoder (lambda (token integer-p) (list token integer-p)))))
      (expect (gethash "foo" value) :to-equal (list "12" t))
      (expect (gethash "n" value) :to-equal (list "1.5" nil))))

  (it "applies object and array hooks"
    (expect (parse "[1,2]" :array-type :list :array-hook #'reverse) :to-equal (list 2 1))
    (expect (= (parse "{\"a\":1}" :object-hook (lambda (object) (gethash "a" object))) 1)
            :to-be-truthy))

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

(describe "stream framing with read-json"
  (it "reads exactly one value at a time, honouring strings and nesting"
    (let ((stream (make-string-input-stream " [1,[2],\"}\"] true \"a\\\"b\" 1e2 null")))
      (expect (read-json stream) :to-equalp #(1 #(2) "}"))
      (expect (read-json stream) :to-be t)
      (expect (read-json stream) :to-equal "a\"b")
      (expect (= (read-json stream) 100.0d0) :to-be-truthy)
      (expect (read-json stream) :to-satisfy #'json-null-p)))

  (it "frames strings, escapes, nested objects, and false"
    (with-input-from-string (stream "[1,\"a\\\"}b\",[2]] {\"k\":{\"n\":0}} false")
      (expect (read-json stream) :to-equalp #(1 "a\"}b" #(2)))
      (let ((object (read-json stream)))
        (expect (= (gethash "n" (gethash "k" object)) 0) :to-be-truthy))
      (expect (read-json stream) :to-satisfy #'json-false-p))
    ;; A mismatched closer ends framing early; PARSE then rejects the fragment.
    (with-input-from-string (stream "[}")
      (signals json-parse-error (read-json stream))))

  (it "preserves whitespace-separated values and rejects glued ones"
    (with-input-from-string (stream "1 2")
      (expect (= (read-json stream) 1) :to-be-truthy)
      (expect (= (read-json stream) 2) :to-be-truthy))
    (dolist (text (list "01" "truefalse" "1-2"))
      (with-input-from-string (stream text)
        (signals json-parse-error (read-json stream)))))

  (it "enforces MAX-INPUT-LENGTH and its validation"
    (signals json-parse-error (read-json (make-string-input-stream "[123]") :max-input-length 4))
    (signals json-parse-error (read-json (make-string-input-stream "0") :max-input-length "1"))
    (signals json-parse-error (read-json (make-string-input-stream "0") :max-input-length -1)))

  (it-each (((#\Return)) ((#\Newline)) ((#\Return #\Newline)))
      "reports line/column 2,2 for a bad byte after the break ~S"
      (break-characters)
    (let* ((newline (coerce break-characters 'string))
           (condition
             (capture-json-parse-error
              (read-json (make-string-input-stream (format nil "[~A0]" newline))
                         :max-input-length (+ 2 (length newline))))))
      (expect (= (json-parse-error-line condition) 2) :to-be-truthy)
      (expect (= (json-parse-error-column condition) 2) :to-be-truthy)))

  (it "rejects output-only and non-character streams"
    (signals json-parse-error (read-json (make-string-output-stream)))
    (let ((path (merge-pathnames
                 (format nil "cl-json-kit-reader-~A.tmp" (gensym))
                 (uiop:temporary-directory))))
      (unwind-protect
           (progn
             (with-open-file (output path :direction :output :if-exists :supersede
                                          :element-type '(unsigned-byte 8))
               (write-byte 49 output))
             (with-open-file (input path :direction :input :element-type '(unsigned-byte 8))
               (signals json-parse-error (read-json input))))
        (ignore-errors (delete-file path))))))

(describe "parse-prefix"
  (it "returns the value and its exclusive end index"
    (multiple-value-bind (value end-index) (parse-prefix "1true")
      (expect value :to-be 1)
      (expect end-index :to-be 1))
    (multiple-value-bind (value end-index)
        (parse-prefix (format nil "xx ~C[1]tail" #\Tab) :index 2 :array-type :list)
      (expect value :to-equal (list 1))
      (expect end-index :to-be 7)))

  (it "leaves trailing whitespace and data unconsumed"
    (multiple-value-bind (value end-index) (parse-prefix "null  rest")
      (expect value :to-satisfy #'json-null-p)
      (expect end-index :to-be 4))
    (signals json-parse-error (parse "null  rest")))

  (it "validates its :INDEX and keyword arguments as parse errors"
    (dolist (index (list -1 5 1/2))
      (signals json-parse-error (parse-prefix "null" :index index)))
    (signals json-parse-error (parse-prefix "null" :index 4))
    (signals json-parse-error (parse-prefix "null" :max-depth))
    (signals json-parse-error (parse-prefix "null" :unknown-option t))
    (signals json-parse-error (parse-prefix "null" "not-a-keyword" t))
    (signals json-parse-error (parse-prefix "null" :index 0 :index 1))
    (multiple-value-bind (value end) (parse-prefix "xnull" :index 1)
      (expect value :to-satisfy #'json-null-p)
      (expect end :to-be 5))
    ;; :INDEX combined with another keyword exercises the option-stripping path.
    (multiple-value-bind (value end) (parse-prefix "xx[1]" :index 2 :array-type :list)
      (expect value :to-equal (list 1))
      (expect end :to-be 5)))

  (it "applies resource and timeout validation"
    (signals json-parse-error (parse-prefix "xx1" :index 2 :max-input-length 2))
    (signals json-parse-error (parse-prefix "null" :timeout-seconds -1)))

  (it "rejects invalid callback designators as parse errors"
    (signals json-parse-error (parse "null" :object-hook (make-symbol "MISSING-CALLBACK")))
    (signals json-parse-error (parse-prefix "null" :array-hook 42))))

(describe "timeouts"
  (it-each ((-1) ("soon"))
      "rejects the invalid timeout ~S at both entry points"
      (timeout)
    (signals json-parse-error (parse "null" :timeout-seconds timeout))
    (with-input-from-string (stream "null")
      (signals json-parse-error (read-json stream :timeout-seconds timeout))))

  (it "rejects a complex timeout value"
    (signals json-parse-error (parse "null" :timeout-seconds (complex 1 2))))

  (it "accepts NIL and non-negative real timeouts"
    (expect (parse "null" :timeout-seconds nil) :to-satisfy #'json-null-p)
    (expect (parse "null" :timeout-seconds 1/2) :to-satisfy #'json-null-p)
    (with-input-from-string (stream "null")
      (expect (read-json stream :timeout-seconds 1/2) :to-satisfy #'json-null-p)))

  #+sbcl
  (it "times out while framing a blocking stream"
      (:tags '(:slow))
    (let ((process (uiop:launch-program (list "sh" "-c" "printf '['; sleep 5; printf ']'")
                                        :output :stream :error-output :stream)))
      (unwind-protect
           (expect (handler-case
                       (progn (read-json (uiop:process-info-output process) :timeout-seconds 0.2)
                              nil)
                     (sb-ext:timeout () t))
                   :to-be-truthy)
        (ignore-errors (uiop:terminate-process process :urgent t))
        (ignore-errors (uiop:wait-process process))))))
