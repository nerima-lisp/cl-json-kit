;;;; t/reader-test.lisp
(in-package #:cl-json-kit/test)

(progn
  (it "parses scalar values with opaque defaults"
    (expect (string= (parse "\"hello\"") "hello") :to-be-truthy)
    (expect (= (parse "42") 42) :to-be-truthy)
    (expect (eq (parse "true") t) :to-be-truthy)
    (expect (json-false-p (parse "false")) :to-be-truthy)
    (expect (json-null-p (parse "null")) :to-be-truthy)
    (expect (not (eq +json-null+ +json-false+)) :to-be-truthy))
  (it "supports explicit scalar mappings"
    (expect (eq (parse "null" :null-value :missing) :missing) :to-be-truthy)
    (expect (eq (parse "false" :false-value nil) nil) :to-be-truthy)
    (expect (eq (parse "true" :true-value :yes) :yes) :to-be-truthy))
  (it "uses string keys and decoder hooks"
    (let ((value (parse "{\"Foo\":12,\"n\":1.5}"
                        :key-decoder (lambda (key) (string-downcase key))
                        :number-decoder (lambda (token integer-p)
                                          (list token integer-p)))))
      (expect (equal (gethash "foo" value) (list "12" t)) :to-be-truthy)
      (expect (equal (gethash "n" value) (list "1.5" nil)) :to-be-truthy))
    (signals error (parse "{}" :key-type :keyword)))
  (it "reads exactly one JSON value from a stream"
  (let ((stream (make-string-input-stream
                 " [1,[2],\"}\"] true \"a\\\"b\" 1e2 null")))
    (expect (equalp (read-json stream) (vector 1 (vector 2) "}")) :to-be-truthy)
    (expect (eq (read-json stream) t) :to-be-truthy)
    (expect (string= (read-json stream) "a\"b") :to-be-truthy)
    (expect (= (read-json stream) 100.0d0) :to-be-truthy)
    (expect (json-null-p (read-json stream)) :to-be-truthy))
  (with-input-from-string (stream "1-2") (signals json-parse-error (read-json stream)))
  (progn (signals json-parse-error (read-json (make-string-input-stream "[123]") :max-input-length 4)) (signals json-parse-error (read-json (make-string-input-stream "0") :max-input-length "1")) (signals json-parse-error (read-json (make-string-input-stream "0") :max-input-length -1)))
  (dolist (newline (list (string #\Return)
                         (string #\Newline)
                         (format nil "~C~C" #\Return #\Newline)))
    (handler-case
        (read-json
          (make-string-input-stream (format nil "[~A0]" newline))
          :max-input-length (+ 2 (length newline)))
      (json-parse-error (condition)
        (expect (= (json-parse-error-line condition) 2) :to-be-truthy)
        (expect (= (json-parse-error-column condition) 2) :to-be-truthy))))
  (signals json-parse-error
    (read-json (make-string-output-stream)))
  (let ((path (merge-pathnames
               (format nil "cl-json-kit-reader-~D-~D.tmp"
                       (get-universal-time) (random 1000000))
               (uiop:temporary-directory))))
    (unwind-protect
         (progn
           (with-open-file (output path :direction :output
                                        :if-exists :supersede
                                        :element-type (quote (unsigned-byte 8)))
             (write-byte 49 output))
           (with-open-file (input path :direction :input
                                       :element-type (quote (unsigned-byte 8)))
             (signals json-parse-error (read-json input))))
      (ignore-errors (delete-file path)))))
  (it "reports stable source coordinates and structured paths"
  (handler-case
      (parse (format nil "{\"outer\": [0,~% nope]}") :context "unit-test")
    (json-parse-error (condition)
      (expect (= (json-parse-error-position condition) 15) :to-be-truthy)
      (expect (= (json-parse-error-line condition) 2) :to-be-truthy)
      (expect (= (json-parse-error-column condition) 2) :to-be-truthy)
      (expect (equal (json-parse-error-path condition) (list "outer" 1)) :to-be-truthy)
      (expect (stringp (json-parse-error-expected condition)) :to-be-truthy)
      (expect (string= (json-parse-error-context condition) "unit-test") :to-be-truthy))))
  (progn
(progn
  (it "supports collection representations and boundaries"
    (expect (equal (parse "[1,[2]]" :array-type :list) (list 1 (list 2))) :to-be-truthy)
    (expect (equal (parse "{\"x\":1}" :object-type :alist) (list (cons "x" 1))) :to-be-truthy)
    (signals json-parse-error (parse "[1,2]" :max-array-elements 1))
    (signals json-parse-error (parse "{\"a\":1,\"a\":2}" :duplicate-key-policy :error)))
  (it "accepts only RFC 8259 whitespace and rejects trailing input"
    (expect (= (parse (format nil "~C~C~C~C1" #\Space #\Tab #\Return #\Newline)) 1) :to-be-truthy)
    (signals json-parse-error (parse (format nil "~C1" #\Page)))
    (signals json-parse-error (parse "true false"))
    (signals json-parse-error (parse "[]x")))
  (it "enforces the RFC 8259 number grammar"
  (dolist (text (list "0" "-0" "10" "-12" "0.5" "1e2" "1E-2" "1e+2"))
    (expect (numberp (parse text)) :to-be-truthy))
  (dolist (text (list "01" "-01" "+1" ".1" "1." "1e" "1e+" "--1"))
    (signals json-parse-error (parse text)))
  (dolist (code (list #xFF11 #x0661 #x0967))
    (let ((text (format nil "[~C]" (code-char code))))
      (signals json-parse-error (parse text))
      (with-input-from-string (stream text)
        (signals json-parse-error (read-json stream)))))
  (let ((large (parse "1e400" :max-exact-exponent 400))
        (small (parse "1e-400" :max-exact-exponent 400)))
    (expect (integerp large) :to-be-truthy)
    (expect (= large (expt 10 400)) :to-be-truthy)
    (expect (rationalp small) :to-be-truthy)
    (expect (= small (/ 1 (expt 10 400))) :to-be-truthy))
  (signals json-parse-error (parse "1e401" :max-exact-exponent 400))
  (signals json-parse-error (parse "1e-401" :max-exact-exponent 400))
  (signals json-parse-error (parse "1e1000000000"))
  (signals json-parse-error (parse "1e-1000000000"))
  (let ((huge-exponent (make-string 512 :initial-element #\9))
        (leading-zero-exponent (make-string 512 :initial-element #\0)))
    (signals json-parse-error
      (parse (concatenate (quote string) "1e" huge-exponent)))
    (signals json-parse-error
      (parse (concatenate (quote string) "1e-" huge-exponent)))
    (expect (= (parse (concatenate (quote string)
                                  "1e" leading-zero-exponent "1"))
               10.0d0)
            :to-be-truthy)
    (let ((negative-zero
            (parse (concatenate (quote string) "-0e" huge-exponent))))
      (expect (zerop negative-zero) :to-be-truthy)
      (expect (= (float-sign negative-zero) -1.0d0) :to-be-truthy)))
  (expect (typep (parse "1.5") (quote double-float)) :to-be-truthy))

  (it "decodes Unicode escapes and rejects invalid strings"
  (expect (char= (char (parse "\"\\u0041\"") 0) #\A) :to-be-truthy)
  (expect (= (char-code (char (parse "\"\\uD83D\\uDE00\"") 0)) #x1F600) :to-be-truthy)
  (signals json-parse-error (parse "\"\\uD800\""))
  (signals json-parse-error (parse "\"\\uDC00\""))
  (signals json-parse-error (parse "\"\\uD800\\u0041\""))
  (dolist (code (list #xFF11 #x0661 #x0967))
    (let ((digit (code-char code)))
      (when digit
        (signals json-parse-error
          (parse (format nil "\"\\u~C000\"" digit))))))
  (signals json-parse-error (parse (format nil "\"a~Cb\"" (code-char 1))))
  (signals json-parse-error (parse "\"\\x\"")))
  (progn
  (it "implements every duplicate-key policy"
    (progn (expect (= (gethash "a" (parse "{\"a\":1,\"a\":2}")) 2) :to-be-truthy) (expect (= (gethash "a" (parse "{\"a\":1,\"a\":2}" :duplicate-key-policy :first)) 1) :to-be-truthy))
    (expect (= (gethash "a" (parse "{\"a\":1,\"a\":2}" :duplicate-key-policy :last)) 2) :to-be-truthy)
    (expect (equal (parse "{\"a\":1,\"a\":2}" :object-type :alist :duplicate-key-policy :preserve)
                   (list (cons "a" 1) (cons "a" 2)))
            :to-be-truthy)
    (let ((decoder (lambda (key) (string-downcase key))))
      (signals json-parse-error
        (parse "{\"A\":1,\"a\":2}" :key-decoder decoder :duplicate-key-policy :error))
      (let ((first (parse "{\"A\":1,\"a\":2}" :key-decoder decoder :duplicate-key-policy :first))
            (last (parse "{\"A\":1,\"a\":2}" :key-decoder decoder :duplicate-key-policy :last)))
        (expect (= (hash-table-count first) 1) :to-be-truthy)
        (expect (= (gethash "a" first) 1) :to-be-truthy)
        (expect (= (hash-table-count last) 1) :to-be-truthy)
        (expect (= (gethash "a" last) 2) :to-be-truthy)))
    (let ((calls 0))
      (signals json-parse-error
        (parse "{\"a\":1,\"A\":2}"
               :key-decoder (function string-downcase)
               :duplicate-key-policy :error
               :number-decoder
               (lambda (token integer-p)
                 (declare (ignore integer-p))
                 (incf calls)
                 (parse-integer token))))
      (expect (= calls 1) :to-be-truthy))
    (progn (signals json-parse-error (parse "{}" :duplicate-key-policy :preserve)) (signals json-parse-error (parse "{}" :object-type :invalid)) (signals json-parse-error (parse "[]" :array-type :invalid)) (signals json-parse-error (parse "{}" :key-type :invalid)) (signals json-parse-error (parse "{}" :duplicate-key-policy :invalid))))
  (it "round-trips duplicate object members through the explicit representation"
    (let* ((text "{\"a\":1,\"a\":2}")
           (members (parse text :object-type :alist :duplicate-key-policy :preserve))
           (object (alist->json-object members :duplicate-key-policy :preserve)))
      (expect (string= (stringify object) text) :to-be-truthy))))
  (it "enforces resource boundaries and EOF positions"
    (expect (equalp (parse "[]" :max-array-elements 0) #()) :to-be-truthy)
    (signals json-parse-error (parse "[0]" :max-array-elements 0))
    (expect (= (hash-table-count (parse "{}" :max-object-members 0)) 0) :to-be-truthy)
    (signals json-parse-error (parse "{\"a\":0}" :max-object-members 0))
    (expect (equalp (parse "[]" :max-depth 1) #()) :to-be-truthy)
    (signals json-parse-error (parse "[[]]" :max-depth 1))
    (expect (string= (parse "\"a\"" :max-string-length 1) "a") :to-be-truthy)
    (signals json-parse-error (parse "\"ab\"" :max-string-length 1))
    (expect (= (parse "1" :max-number-length 1) 1) :to-be-truthy)
    (signals json-parse-error (parse "12" :max-number-length 1))
    (signals json-parse-error (parse "null" :max-input-length 3))
    (dolist (text (list "" "[" "[1" "[1," "{" "{\"a\"" "{\"a\":" "\"" "\"\\" "tru" "-" "1e"))
      (signals json-parse-error (parse text))))
  (it "treats CRLF as one source line while preserving paths"
    (dolist (newline (list (string #\Return) (string #\Newline)
                           (format nil "~C~C" #\Return #\Newline)))
      (handler-case
          (parse (format nil "{\"a\":[0,~A ?]}" newline))
        (json-parse-error (condition)
          (expect (= (json-parse-error-line condition) 2) :to-be-truthy)
          (expect (= (json-parse-error-column condition) 2) :to-be-truthy)
          (expect (equal (json-parse-error-path condition) (list "a" 1)) :to-be-truthy)))))
  (it "validates non-negative resource limits" (signals json-parse-error (parse "null" :max-depth -1)) (signals json-parse-error (parse "null" :max-array-elements 1.5)) (signals json-parse-error (parse "null" :max-exact-exponent -1))))
(it "reports the offending key in duplicate-key errors"
  (let ((condition
          (handler-case
              (progn
                (parse "{\"a\":1,\"a\":2}" :duplicate-key-policy :error)
                nil)
            (json-parse-error (condition) condition))))
    (expect (typep condition 'json-parse-error) :to-be-truthy)
    (expect (equal (json-parse-error-path condition) (list "a")) :to-be-truthy)))
(it "applies object and array hooks"
  (expect (equal (parse "[1,2]" :array-type :list :array-hook #'reverse)
                 (list 2 1))
          :to-be-truthy)
  (expect (= (parse "{\"a\":1}"
                    :object-hook (lambda (object) (gethash "a" object)))
             1)
          :to-be-truthy))
(it "normalizes parser callback errors with their JSON paths"
  (dolist (case
            (list
              (list "{\"key\":1}"
                    (list :key-decoder (lambda (key)
                                         (declare (ignore key))
                                         (error "key boom")))
                    (list "key") "key boom")
              (list "{\"number\":1}"
                    (list :number-decoder (lambda (token integer-p)
                                            (declare (ignore token integer-p))
                                            (error "number boom")))
                    (list "number") "number boom")
              (list "{\"object\":{}}"
                    (list :object-hook (lambda (object)
                                         (declare (ignore object))
                                         (error "object boom")))
                    (list "object") "object boom")
              (list "{\"array\":[]}"
                    (list :array-hook (lambda (array)
                                        (declare (ignore array))
                                        (error "array boom")))
                    (list "array") "array boom")))
    (destructuring-bind (text options path diagnostic) case
      (let ((condition
              (handler-case
                  (progn (apply #'parse text options) nil)
                (json-parse-error (condition) condition))))
        (expect (typep condition 'json-parse-error) :to-be-truthy)
        (expect (equal (json-parse-error-path condition) path) :to-be-truthy)
        (expect (search diagnostic (json-parse-error-expected condition))
                :to-be-truthy)))))
(it "does not wrap an existing JSON parse error from a callback"
  (let* ((original
           (make-condition 'json-parse-error
                           :position 7
                           :line 1
                           :column 8
                           :path (list "original")
                           :expected "original callback error"
                           :context "test"
                           :text ""))
         (caught
           (handler-case
               (progn
                 (parse "1"
                        :number-decoder
                        (lambda (token integer-p)
                          (declare (ignore token integer-p))
                          (error original)))
                 nil)
             (json-parse-error (condition) condition))))
    (expect (eq caught original) :to-be-truthy)))
#+sbcl
(it "times out while framing a blocking stream"
  (let ((process
          (uiop:launch-program
            (list "sh" "-c" "printf '['; sleep 5; printf ']'")
            :output :stream
            :error-output :stream)))
    (unwind-protect
         (expect
           (handler-case
               (progn
                 (read-json (uiop:process-info-output process) :timeout-seconds 0.2)
                 nil)
             (sb-ext:timeout () t))
           :to-be-truthy)
      (ignore-errors (uiop:terminate-process process :urgent t))
      (ignore-errors (uiop:wait-process process)))))
))

(progn (it "accepts zero coefficients with exponents beyond the exact limit" (let ((positive (parse "0e10001")) (negative (parse "-0e10001"))) (expect (typep positive (quote double-float)) :to-be-truthy) (expect (zerop positive) :to-be-truthy) (expect (typep negative (quote double-float)) :to-be-truthy) (expect (zerop negative) :to-be-truthy) (expect (= (float-sign negative) -1.0d0) :to-be-truthy))) (it "normalizes invalid timeout values at public entry points" (dolist (timeout (list -1 "soon" (complex 1 2))) (signals json-parse-error (parse "null" :timeout-seconds timeout)) (with-input-from-string (stream "null") (signals json-parse-error (read-json stream :timeout-seconds timeout))))) (it "accepts NIL and non-negative real timeout values" (expect (json-null-p (parse "null" :timeout-seconds nil)) :to-be-truthy) (expect (json-null-p (parse "null" :timeout-seconds 1/2)) :to-be-truthy) (with-input-from-string (stream "null") (expect (json-null-p (read-json stream :timeout-seconds 1/2)) :to-be-truthy))))

(progn (progn (it "rejects adjacent stream values without JSON whitespace" (dolist (text (list "01" "truefalse")) (with-input-from-string (stream text) (signals json-parse-error (read-json stream))))) (it "preserves whitespace-separated stream values" (with-input-from-string (stream "1 2") (expect (= (read-json stream) 1) :to-be-truthy) (expect (= (read-json stream) 2) :to-be-truthy))) (it "requires KEY-DECODER to return a string with the key path" (let ((condition (handler-case (progn (parse "{\"key\":1}" :key-decoder (lambda (key) (declare (ignore key)) 42)) nil) (json-parse-error (condition) condition)))) (expect (typep condition (quote json-parse-error)) :to-be-truthy) (expect (equal (json-parse-error-path condition) (list "key")) :to-be-truthy) (expect (search "KEY-DECODER" (json-parse-error-expected condition)) :to-be-truthy)))) (progn
  (defun symbol-number-decoder (token integer-p)
    (declare (ignore integer-p))
    (concatenate 'string "number:" token))
  (it "parses a value prefix and returns its exclusive end index"
    (multiple-value-bind (value end-index)
        (parse-prefix "1true")
      (expect (= value 1) :to-be-truthy)
      (expect (= end-index 1) :to-be-truthy))
    (multiple-value-bind (value end-index)
        (parse-prefix (format nil "xx ~C[1]tail" #\Tab) 2 :array-type :list)
      (expect (equal value (list 1)) :to-be-truthy)
      (expect (= end-index 7) :to-be-truthy)))
  (it "leaves trailing whitespace and data unconsumed"
    (multiple-value-bind (value end-index)
        (parse-prefix "null  rest")
      (expect (json-null-p value) :to-be-truthy)
      (expect (= end-index 4) :to-be-truthy))
    (signals json-parse-error (parse "null  rest")))
  (it "validates parse-prefix arguments as JSON parse errors"
    (dolist (index (list -1 5 1/2))
      (signals json-parse-error (parse-prefix "null" index)))
    (signals json-parse-error (parse-prefix "null" 4))
    (signals json-parse-error (parse-prefix "null" :max-depth))
    (signals json-parse-error (parse-prefix "null" :unknown-option t))
    (signals json-parse-error (parse-prefix "null" 0 "not-a-keyword" t))
    (signals json-parse-error (parse-prefix "null" 0 :index 0))
    (signals json-parse-error (parse-prefix "null" :index 0 :index 1))
    (multiple-value-bind (value end) (parse-prefix "xnull" :index 1)
      (expect (json-null-p value) :to-be-truthy)
      (expect (= 5 end) :to-be-truthy)))
  (it "applies parse-prefix resource and timeout validation"
    (signals json-parse-error
      (parse-prefix "xx1" 2 :max-input-length 2))
    (signals json-parse-error
      (parse-prefix "null" 0 :timeout-seconds -1)))
  (it "accepts fbound symbols as parser callback designators"
    (let ((object
            (parse "{\"KEY\":1}" :key-decoder 'string-downcase)))
      (expect (= (gethash "key" object) 1) :to-be-truthy))
    (expect (equal (parse "2" :number-decoder 'symbol-number-decoder)
                   "number:2")
            :to-be-truthy)
    (expect (= (parse "{\"a\":1}" :object-hook 'hash-table-count) 1)
            :to-be-truthy)
    (expect (equalp (parse "[1,2]" :array-hook 'reverse) #(2 1))
            :to-be-truthy))
  (it "normalizes invalid callback designators as JSON parse errors"
    (signals json-parse-error
      (parse "null" :object-hook (make-symbol "MISSING-CALLBACK")))
    (signals json-parse-error
      (parse-prefix "null" 0 :array-hook 42)))))
