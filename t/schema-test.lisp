;;;; t/schema-test.lisp
(in-package #:cl-json-kit/test)

(defun validate-json-text (value schema)
  (validate-schema (parse value) (parse schema)))

(describe "JSON Schema subset"
  (it "checks each type against every default JSON value kind"
    (let ((cases '(("null" "null") ("true" "boolean") ("false" "boolean")
                   ("{}" "object") ("[]" "array") ("\"text\"" "string")
                   ("3" "integer") ("1.5" "number") ("1.0" "integer")
                   ("-0.0" "integer") ("1e0" "integer"))))
      (dolist (type '("null" "boolean" "object" "array" "string" "integer" "number"))
        (dolist (case cases)
          (let ((expected (or (string= type (second case))
                              (and (string= type "number")
                                   (string= (second case) "integer")))))
            (expect (validate-json-text (first case) (format nil "{\"type\":~S}" type))
                    :to-equal (and expected t)))))))

  (it "accepts any declared type in a type array"
    (dolist (value '("null" "\"text\""))
      (expect (validate-json-text value "{\"type\":[\"null\",\"string\"]}") :to-be-truthy))
    (expect (validate-json-text "1" "{\"type\":[\"null\",\"string\"]}") :to-be-falsy))

  (it "reports all missing required properties and distinguishes present null and false"
    (multiple-value-bind (valid errors)
        (validate-json-text "{\"present\":null,\"false\":false}"
                            "{\"required\":[\"present\",\"false\",\"a\",\"b\"]}")
      (expect valid :to-be-falsy)
      (expect (mapcar (lambda (error) (getf error :path)) errors)
              :to-equal '("/a" "/b"))
      (expect (every (lambda (error) (plusp (length (getf error :reason)))) errors)
              :to-be-truthy))
    (expect (validate-json-text "{}" "{\"required\":[]}") :to-be-truthy)
    (expect (validate-json-text "4" "{\"required\":[\"a\"]}") :to-be-truthy))

  (it "combines properties with omitted true false and schema additionalProperties"
    (dolist (extra '("" ",\"additionalProperties\":true"))
      (expect (validate-json-text "{\"name\":\"Ada\",\"age\":10}"
                                 (format nil "{\"properties\":{\"name\":{\"type\":\"string\"}}~A}" extra))
              :to-be-truthy)
      (expect (validate-json-text "{\"name\":10}"
                                 (format nil "{\"properties\":{\"name\":{\"type\":\"string\"}}~A}" extra))
              :to-be-falsy))
    (expect (validate-json-text "{\"name\":\"Ada\"}"
                               "{\"properties\":{\"name\":{\"type\":\"string\"}},\"additionalProperties\":false}")
            :to-be-truthy)
    (expect (validate-json-text "{\"name\":\"Ada\",\"age\":10}"
                               "{\"properties\":{\"name\":{\"type\":\"string\"}},\"additionalProperties\":false}")
            :to-be-falsy)
    (expect (validate-json-text "{\"name\":\"Ada\",\"age\":10}"
                               "{\"properties\":{\"name\":{\"type\":\"string\"}},\"additionalProperties\":{\"type\":\"integer\"}}")
            :to-be-truthy)
    (expect (validate-json-text "{\"name\":\"Ada\",\"age\":\"ten\"}"
                               "{\"properties\":{\"name\":{\"type\":\"string\"}},\"additionalProperties\":{\"type\":\"integer\"}}")
            :to-be-falsy)
    (dolist (schema '("{\"additionalProperties\":true}"
                      "{\"additionalProperties\":{\"type\":\"integer\"}}"))
      (expect (validate-json-text "{\"age\":10}" schema) :to-be-truthy))
    (expect (validate-json-text "{\"age\":10}" "{\"additionalProperties\":false}") :to-be-falsy)
    (expect (validate-json-text "{\"age\":\"ten\"}" "{\"additionalProperties\":{\"type\":\"integer\"}}")
            :to-be-falsy)
    (expect (validate-json-text "4" "{\"properties\":{\"x\":false},\"additionalProperties\":false}")
            :to-be-truthy))

  (it "compares enum values by JSON type and structural value"
    (dolist (pair '(("null" "null") ("true" "true") ("false" "false")
                    ("\"a\"" "\"a\"") ("1" "1.0") ("1.5" "1.5")
                    ("[1,{\"a\":false}]" "[1.0,{\"a\":false}]")
                    ("{\"a\":1,\"b\":2}" "{\"b\":2,\"a\":1.0}")))
      (expect (validate-json-text (first pair) (format nil "{\"enum\":[~A]}" (second pair)))
              :to-be-truthy))
    (dolist (pair '(("false" "null") ("true" "1") ("1" "\"1\"")
                    ("[]" "{}") ("[1,2]" "[2,1]") ("[1]" "[1,2]")
                    ("{\"a\":1}" "{\"a\":2}") ("{\"a\":null}" "{\"b\":null}")))
      (expect (validate-json-text (first pair) (format nil "{\"enum\":[~A]}" (second pair)))
              :to-be-falsy))
    (expect (validate-json-text "null" "{\"enum\":[]}") :to-be-falsy)
    (expect (validate-json-text "false" "{\"enum\":[1,\"x\",false]}") :to-be-truthy))

  (it "validates nested items and escapes JSON Pointer member names"
    (let ((schema "{\"properties\":{\"a/b~c\":{\"items\":{\"items\":{\"type\":\"integer\"}}}}}"))
      (multiple-value-bind (valid errors)
          (validate-json-text "{\"a/b~c\":[[1,\"bad\"],[false]]}" schema)
        (expect valid :to-be-falsy)
        (expect (mapcar (lambda (error) (getf error :path)) errors)
                :to-equal '("/a~1b~0c/0/1" "/a~1b~0c/1/0")))
      (expect (validate-json-text "{\"a/b~c\":[[1],[2,3]]}" schema) :to-be-truthy))
    (expect (validate-json-text "[]" "{\"items\":false}") :to-be-truthy)
    (expect (validate-json-text "[1]" "{\"items\":false}") :to-be-falsy)
    (expect (validate-json-text "1" "{\"items\":false}") :to-be-truthy))

  (it "requires exactly one matching oneOf alternative"
    (let ((schema "{\"oneOf\":[{\"type\":\"number\"},{\"type\":\"integer\"}]}"))
      (multiple-value-bind (valid errors) (validate-json-text "\"x\"" schema)
        (expect valid :to-be-falsy)
        (expect (getf (first errors) :path) :to-equal "")
        (expect (search "matched 0" (getf (first errors) :reason)) :to-be-truthy))
      (expect (multiple-value-list (validate-json-text "1.5" schema)) :to-equal '(t nil))
      (multiple-value-bind (valid errors) (validate-json-text "1" schema)
        (expect valid :to-be-falsy)
        (expect (search "matched 2" (getf (first errors) :reason)) :to-be-truthy)))
    (expect (validate-json-text "1" "{\"oneOf\":[true,true,true]}") :to-be-falsy))

  (it "supports boolean schemas and empty schema objects"
    (dolist (value '("null" "false" "[]" "{}" "1"))
      (expect (multiple-value-list (validate-json-text value "true")) :to-equal '(t nil))
      (expect (validate-json-text value "{}") :to-be-truthy)
      (expect (validate-json-text value "false") :to-be-falsy)))

  (it "rejects unsupported keywords before choosing instance branches"
    (dolist (schema '("{\"minLength\":1}"
                      "{\"properties\":{\"unused\":{\"format\":\"date\"}}}"
                      "{\"items\":{\"minimum\":1}}"
                      "{\"additionalProperties\":{\"maximum\":1}}"
                      "{\"oneOf\":[true,{\"const\":1}]}"))
      (signals json-schema-error (validate-json-text "null" schema)))
    (handler-case (progn
                    (validate-json-text "{}" "{\"properties\":{\"a/b~c\":{\"bad\":1}}}")
                    (error "Expected JSON-SCHEMA-ERROR"))
      (json-schema-error (condition)
        (expect (json-schema-error-path condition) :to-equal "/properties/a~1b~0c/bad")
        (expect (json-schema-error-message condition) :to-equal "Unsupported schema keyword"))))

  (it "rejects malformed supported keyword values"
    (dolist (schema '("null" "[]" "{\"type\":\"unknown\"}" "{\"type\":[]}"
                      "{\"type\":[\"null\",\"null\"]}" "{\"type\":[1]}"
                      "{\"required\":true}" "{\"required\":[1]}"
                      "{\"required\":[\"a\",\"a\"]}"
                      "{\"properties\":[]}" "{\"properties\":{\"x\":1}}"
                      "{\"enum\":null}" "{\"items\":[]}"
                      "{\"additionalProperties\":null}" "{\"oneOf\":{}}"
                      "{\"oneOf\":[]}" "{\"oneOf\":[true,1]}"))
      (signals json-schema-error (validate-json-text "null" schema))))

  (it "rejects non-default Lisp representations even with an empty schema"
    (dolist (value (list nil :null '(1 2) 1/3 #c(1 2)))
      (expect (validate-schema value (parse "{}")) :to-be-falsy))
    (expect (validate-schema (make-hash-table :test #'equal) (parse "{}")) :to-be-truthy)
    #+sbcl
    (expect (validate-schema sb-ext:double-float-positive-infinity (parse "{}")) :to-be-falsy))

  (it "validates the D70 envelope shape and error code enumeration"
    (let* ((schema (parse "{\"type\":\"object\",\"required\":[\"nshell_api\",\"ok\",\"status\",\"duration_ms\",\"stdout\",\"stderr\",\"effects\",\"safety\",\"state\"],\"additionalProperties\":true,\"properties\":{\"nshell_api\":{\"type\":\"string\"},\"ok\":{\"type\":\"boolean\"},\"status\":{\"type\":\"integer\"},\"duration_ms\":{\"type\":\"number\"},\"stdout\":{\"type\":\"string\"},\"stderr\":{\"type\":\"string\"},\"effects\":{\"type\":\"array\",\"items\":{\"type\":\"object\"}},\"safety\":{\"type\":\"object\"},\"state\":{\"type\":\"object\"},\"error\":{\"type\":\"object\",\"required\":[\"code\"],\"properties\":{\"code\":{\"enum\":[\"invalid_argument\",\"internal_error\"]}}}}}"))
           (value (parse "{\"nshell_api\":\"0.8\",\"ok\":false,\"status\":1,\"duration_ms\":0.5,\"stdout\":\"\",\"stderr\":\"bad\",\"effects\":[],\"safety\":{},\"state\":{},\"optional\":true,\"error\":{\"code\":\"invalid_argument\"}}")))
      (expect (multiple-value-list (validate-schema value schema)) :to-equal '(t nil))
      (setf (gethash "code" (gethash "error" value)) "unknown")
      (multiple-value-bind (valid errors) (validate-schema value schema)
        (expect valid :to-be-falsy)
        (expect (getf (first errors) :path) :to-equal "/error/code"))
      (remhash "stdout" value)
      (expect (validate-schema value schema) :to-be-falsy)))
  (it "validates exact decimal numbers beyond double-float range"
    (dolist (text (list "1e-400" "-1e-400" "1e400" "-1e400"))
      (expect (validate-json-text text "{\"type\":\"number\"}") :to-be-truthy))
    (expect (typep (parse "1e-400") (quote ratio)) :to-be-truthy)
    (expect (integerp (parse "1e400")) :to-be-truthy)
    (expect (validate-json-text "1e-400" "{\"type\":\"integer\"}") :to-be-falsy)
    (expect (validate-json-text "1e400" "{\"type\":\"integer\"}") :to-be-truthy)
    (expect (validate-json-text "1e-400" "{\"enum\":[10e-401]}") :to-be-truthy)
    (expect (validate-schema 1/3 (parse "{\"type\":\"number\"}")) :to-be-falsy))
  (it "keeps JSON Pointer array indices decimal under printer bindings"
    (let ((value (make-array 11 :initial-element 1))
          (schema (parse "{\"items\":{\"type\":\"integer\"}}"))
          (*print-base* 16)
          (*print-radix* t))
      (setf (aref value 10) "bad")
      (multiple-value-bind (valid errors) (validate-schema value schema)
        (expect valid :to-be-falsy)
        (expect (getf (first errors) :path) :to-equal "/10"))))
  (it "rejects non-EQUAL hash tables anywhere in the schema tree"
    (let ((bad (make-hash-table)))
      (setf (gethash (copy-seq "type") bad) "integer")
      (dolist (schema (list bad
                            (let ((parent (parse "{\"properties\":{}}")))
                              (setf (gethash "properties" parent) bad) parent)
                            (let ((parent (parse "{\"properties\":{}}")))
                              (setf (gethash "unused" (gethash "properties" parent)) bad) parent)
                            (let ((parent (parse "{\"enum\":[]}")))
                              (setf (gethash "enum" parent) (vector bad)) parent)))
        (signals json-schema-error (validate-schema (parse "null") schema))))
    (expect (validate-json-text "1" "{\"type\":\"integer\"}") :to-be-truthy))
  (it "bounds and escapes retained schema condition slots exactly once"
    (let* ((condition (json-kit::bounded-json-schema-error
                       :path (format nil "/~C~A" #\Newline (make-string 400 :initial-element #\k))
                       :message (format nil "~C~A" #\Tab (make-string 400 :initial-element #\m))))
           (path (json-schema-error-path condition))
           (message (json-schema-error-message condition))
           (report (princ-to-string condition)))
      (expect (length path) :to-equal 256)
      (expect (subseq path 0 3) :to-equal "/\\n")
      (expect (length message) :to-equal 256)
      (expect (subseq message 0 2) :to-equal "\\t")
      (expect (search path report) :to-be-truthy)
      (expect (search message report) :to-be-truthy)
      (expect (find #\Newline report) :to-be-falsy)
      (expect (find #\Tab report) :to-be-falsy)
      (expect (<= (length report) 540) :to-be-truthy)))
  (it "bounds signalled schema paths while keeping validation pointers exact"
    (let* ((key (format nil "~C~A" #\Newline (make-string 400 :initial-element #\x)))
           (unknown (make-hash-table :test #'equal))
           (nested (parse "{\"properties\":{}}")))
      (setf (gethash key unknown) t
            (gethash key (gethash "properties" nested)) (make-hash-table))
      (dolist (schema (list unknown nested))
        (let* ((condition (handler-case
                              (progn (validate-schema (parse "{}") schema)
                                     (error "Expected JSON-SCHEMA-ERROR"))
                            (json-schema-error (condition) condition)))
               (path (json-schema-error-path condition))
               (report (princ-to-string condition)))
          (expect (length path) :to-equal 256)
          (expect (search "\\n" path) :to-be-truthy)
          (expect (find #\Newline path) :to-be-falsy)
          (expect (search path report) :to-be-truthy)
          (expect (find #\Newline report) :to-be-falsy)
          (expect (<= (length (json-schema-error-message condition)) 256) :to-be-truthy)
          (expect (<= (length report) 540) :to-be-truthy)))
      (let ((schema (parse "{\"required\":[]}")))
        (setf (gethash "required" schema) (vector key))
        (multiple-value-bind (valid errors) (validate-schema (parse "{}") schema)
          (expect valid :to-be-falsy)
          (expect (getf (first errors) :path) :to-equal (concatenate 'string "/" key)))))))
