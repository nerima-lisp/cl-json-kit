;;;; t/reader-streaming-test.lisp
(in-package #:cl-json-kit/test)

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
