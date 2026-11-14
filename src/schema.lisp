;;;; src/schema.lisp
(in-package #:json-kit)

(define-condition json-schema-error (json-kit-error)
  ((path :initarg :path :reader json-schema-error-path
         :documentation "Bounded, escaped excerpt of the JSON Pointer into the schema.")
   (message :initarg :message :reader json-schema-error-message
            :documentation "Bounded, escaped explanation of the schema error."))
  (:documentation "An unsupported keyword or malformed schema, detected before validation.
Library-signalled conditions store PATH and MESSAGE as escaped diagnostic
excerpts of at most 256 characters each.")
  (:report (lambda (condition stream)
             (format stream "JSON schema error at ~A: ~A"
                     (json-schema-error-path condition)
                     (json-schema-error-message condition)))))

(setf (documentation 'json-schema-error-path 'function)
      "Bounded, escaped excerpt of the schema JSON Pointer, at most 256 characters.
This diagnostic may be truncated and is not an exact machine-readable pointer."
      (documentation 'json-schema-error-message 'function)
      "Bounded, escaped explanation of the schema error, at most 256 characters.")
(defun bounded-json-schema-error (&key path message)
  "Construct a JSON-SCHEMA-ERROR with diagnostic slots bounded and escaped once.
Use this constructor at library signalling sites, as for BOUNDED-JSON-PARSE-ERROR."
  (make-condition 'json-schema-error
                  :path (safe-diagnostic-snippet path)
                  :message (safe-diagnostic-snippet message)))

(defun schema-pointer-child (pointer token)
  (concatenate 'string pointer "/"
               (with-output-to-string (stream)
                 (loop for character across (if (integerp token) (format nil "~D" token) token)
                       do (case character
                            (#\~ (write-string "~0" stream))
                            (#\/ (write-string "~1" stream))
                            (otherwise (write-char character stream)))))))

(defun schema-array-p (value)
  (and (vectorp value) (not (stringp value))))

(defun schema-number-p (value)
  (or (integerp value)
      (and (floatp value) (finite-float-p value))
      (and (typep value (quote ratio))
           (let ((after-twos (nth-value 1 (factor-count (denominator value) 2))))
             (= (nth-value 1 (factor-count after-twos 5)) 1)))))

(defun schema-json-value-p (value)
  (cond
    ((or (stringp value) (schema-number-p value)
         (eq value t) (json-null-p value) (json-false-p value)) t)
    ((schema-array-p value) (every #'schema-json-value-p value))
    ((hash-table-p value)
     (loop for key being the hash-keys of value using (hash-value child)
           always (and (stringp key) (schema-json-value-p child))))
    (t nil)))

(defun schema-json-equal-p (left right)
  (cond
    ((and (schema-number-p left) (schema-number-p right))
     (= (rational left) (rational right)))
    ((and (stringp left) (stringp right)) (string= left right))
    ((and (schema-array-p left) (schema-array-p right))
     (and (= (length left) (length right))
          (every #'schema-json-equal-p left right)))
    ((and (hash-table-p left) (hash-table-p right))
     (and (= (hash-table-count left) (hash-table-count right))
          (loop for key being the hash-keys of left using (hash-value value)
                always (multiple-value-bind (other present-p) (gethash key right)
                         (and present-p (schema-json-equal-p value other))))))
    (t (eq left right))))

(defun check-json-schema (schema pointer)
  (labels ((fail (path message)
             (error (bounded-json-schema-error :path path :message message)))
           (type-name-p (value)
             (and (stringp value)
                  (member value '("null" "boolean" "object" "array" "number"
                                  "string" "integer") :test #'string=)))
           (unique-strings-p (value)
             (and (schema-array-p value) (every #'stringp value)
                  (= (length value)
                     (length (remove-duplicates value :test #'string=))))))
    (cond
      ((or (eq schema t) (json-false-p schema)))
      ((not (hash-table-p schema)) (fail pointer "Expected a schema object or boolean"))
      (t
       (maphash
        (lambda (keyword value)
          (unless (stringp keyword) (fail pointer "Schema keys must be strings"))
          (let ((path (schema-pointer-child pointer keyword)))
            (cond
              ((string= keyword "type")
               (unless (or (type-name-p value)
                           (and (unique-strings-p value) (plusp (length value))
                                (every #'type-name-p value)))
                 (fail path "Expected a type name or nonempty array of unique type names")))
              ((string= keyword "required")
               (unless (unique-strings-p value)
                 (fail path "Expected an array of unique property names")))
              ((string= keyword "properties")
               (unless (hash-table-p value) (fail path "Expected an object of schemas"))
               (maphash (lambda (key child)
                          (unless (stringp key) (fail path "Property names must be strings"))
                          (check-json-schema child (schema-pointer-child path key)))
                        value))
              ((string= keyword "enum")
               (unless (and (schema-array-p value) (every #'schema-json-value-p value))
                 (fail path "Expected an array of JSON values")))
              ((or (string= keyword "items") (string= keyword "additionalProperties"))
               (check-json-schema value path))
              ((string= keyword "oneOf")
               (unless (and (schema-array-p value) (plusp (length value)))
                 (fail path "Expected a nonempty array of schemas"))
               (loop for child across value for index from 0
                     do (check-json-schema child (schema-pointer-child path index))))
              (t (fail path "Unsupported schema keyword")))))
        schema)))))

(defun schema-type-matches-p (value type)
  (cond
    ((string= type "null") (json-null-p value))
    ((string= type "boolean") (or (eq value t) (json-false-p value)))
    ((string= type "object") (hash-table-p value))
    ((string= type "array") (schema-array-p value))
    ((string= type "number") (schema-number-p value))
    ((string= type "string") (stringp value))
    ((string= type "integer")
     (and (schema-number-p value) (zerop (nth-value 1 (truncate value)))))))

(defun schema-validation-errors (value schema pointer)
  (let ((errors nil))
    (labels ((fail (path reason) (push (list :path path :reason reason) errors))
             (validate-child (child child-schema path)
               (dolist (failure (schema-validation-errors child child-schema path))
                 (push failure errors))))
      (cond
        ((eq schema t))
        ((json-false-p schema) (fail pointer "Rejected by false schema"))
        (t
         (multiple-value-bind (types present-p) (gethash "type" schema)
           (when (and present-p
                      (not (if (stringp types)
                               (schema-type-matches-p value types)
                               (some (lambda (type) (schema-type-matches-p value type)) types))))
             (fail pointer "Value does not match the allowed type")))
         (multiple-value-bind (choices present-p) (gethash "enum" schema)
           (when (and present-p
                      (not (some (lambda (choice) (schema-json-equal-p value choice)) choices)))
             (fail pointer "Value is not in enum")))
         (when (hash-table-p value)
           (loop for key across (gethash "required" schema #())
                 unless (nth-value 1 (gethash key value))
                   do (fail (schema-pointer-child pointer key) "Required property is missing"))
           (let ((properties (gethash "properties" schema))
                 (additional (gethash "additionalProperties" schema t)))
             (maphash
              (lambda (key child)
                (multiple-value-bind (child-schema present-p)
                    (if properties (gethash key properties) (values nil nil))
                  (validate-child child (if present-p child-schema additional)
                                  (schema-pointer-child pointer key))))
              value)))
         (when (schema-array-p value)
           (multiple-value-bind (items present-p) (gethash "items" schema)
             (when present-p
               (loop for child across value for index from 0
                     do (validate-child child items (schema-pointer-child pointer index))))))
         (multiple-value-bind (alternatives present-p) (gethash "oneOf" schema)
           (when present-p
             (let* ((results (loop for alternative across alternatives
                                   collect (schema-validation-errors value alternative pointer)))
                    (matches (loop for failures in results for index from 0
                                   unless failures collect index)))
               (unless (= (length matches) 1)
                 (fail pointer
                       (with-output-to-string (stream)
                         (format stream "oneOf matched ~D schemas; expected exactly one" (length matches))
                         (if matches
                             (format stream "; matched indices: ~{~D~^, ~}" matches)
                             (loop for failures in results for index from 0
                                   do (format stream "; branch ~D" index)
                                      (dolist (failure failures)
                                        (format stream " [path ~S: ~A]"
                                                (getf failure :path)
                                                (getf failure :reason)))))))))))))
      (nreverse errors))))
(defun check-schema-table-tests (value pointer)
  (cond
    ((hash-table-p value)
     (unless (eq (hash-table-test value) (quote equal))
       (error (bounded-json-schema-error :path pointer :message "Schema hash tables must use EQUAL")))
     (maphash (lambda (key child)
                (check-schema-table-tests child
                                          (if (stringp key)
                                              (schema-pointer-child pointer key)
                                              pointer)))
              value))
    ((schema-array-p value)
     (loop for child across value for index from 0
           do (check-schema-table-tests child (schema-pointer-child pointer index))))))

(defun validate-schema (value schema)
  "Validate VALUE against the supported JSON Schema subset. Return a boolean and
a list of (:PATH JSON-Pointer :REASON string) failures. Both arguments use the
default PARSE representation. Unsupported keywords and malformed schemas signal
JSON-SCHEMA-ERROR before any instance validation, including in unused branches."
  (check-schema-table-tests schema "")
  (check-json-schema schema "")
  (let ((errors (if (schema-json-value-p value)
                    (schema-validation-errors value schema "")
                    (list (list :path "" :reason "Value is not in the default JSON representation")))))
    (values (null errors) errors)))
