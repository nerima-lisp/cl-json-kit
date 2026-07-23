;;;; t/writer-test.lisp

(in-package #:cl-json-kit/test)

(it "stringifies basic scalar types"
  (expect (string= (stringify "hello") "\"hello\"") :to-be-truthy)
  (expect (string= (stringify 42) "42") :to-be-truthy)
  (expect (string= (stringify t) "true") :to-be-truthy)
  (expect (string= (stringify :false) "false") :to-be-truthy)
  (expect (string= (stringify :null) "null") :to-be-truthy)
  (expect (string= (stringify nil) "[]") :to-be-truthy))

(it "stringifies a hash-table as a JSON object"
  (let ((table (make-hash-table :test #'equal)))
    (setf (gethash "a" table) 1)
    (expect (string= (stringify table) "{\"a\":1}") :to-be-truthy)))

(it "stringifies a vector as a JSON array, including nested vectors"
  (expect (string= (stringify #(1 2 #(3 4))) "[1,2,[3,4]]") :to-be-truthy))

(it "stringifies a plain proper list as a JSON array"
  (expect (string= (stringify (list 1 2 3)) "[1,2,3]") :to-be-truthy)
  (expect (string= (stringify (list "a" "b")) "[\"a\",\"b\"]") :to-be-truthy))

;;; Regression: the whole point of this library.  A list of conses must
;;; never be reinterpreted as an alist/object by inspecting its shape -- it
;;; is written as an array of arrays, exactly like any other list-of-lists,
;;; because STRINGIFY dispatches purely on Lisp type (LIST => array), not on
;;; whether the elements happen to be (KEY . VALUE) pairs.
(it "never guesses that a list of conses is an alist meant to be an object"
  (expect (string= (stringify (list (cons 1 2) (cons 3 4))) "[[1,2],[3,4]]")
          :to-be-truthy)
  (expect (string= (stringify (list (cons 1 2) (cons 3 4)))
                    (stringify (list (list 1 2) (list 3 4))))
          :to-be-truthy))

(it "requires an explicit alist->json-object wrapper to write an alist as an object"
  (let* ((alist (list (cons "a" 1) (cons "b" 2)))
         (json (stringify (alist->json-object alist))))
    (expect (and (search "\"a\":1" json) (search "\"b\":2" json)) :to-be-truthy)
    (expect (and (char= (char json 0) #\{) (char= (char json (1- (length json))) #\})) :to-be-truthy)))

(it "round-trips hash-table objects through json-object->alist"
  (let ((table (make-hash-table :test #'equal)))
    (setf (gethash "a" table) 1)
    (setf (gethash "b" table) 2)
    (let ((alist (json-object->alist table)))
      (expect (= (cdr (assoc "a" alist :test #'string=)) 1) :to-be-truthy)
      (expect (= (cdr (assoc "b" alist :test #'string=)) 2) :to-be-truthy))))

(it "escapes quotes, backslashes, and control characters in strings"
  (let ((input (concatenate 'string "a\"b\\c" (string #\Newline) "d" (string #\Tab) "e")))
    (expect (string= (stringify input) "\"a\\\"b\\\\c\\nd\\te\"") :to-be-truthy))
  (expect (string= (stringify (string (code-char #x01))) "\"\\u0001\"") :to-be-truthy))

(it "produces indented output when pretty is true"
  (let ((table (make-hash-table :test #'equal)))
    (setf (gethash "a" table) 1)
    (expect (string= (stringify table :pretty t)
                      (format nil "{~%  \"a\": 1~%}"))
            :to-be-truthy)
    (expect (string= (stringify (list 1 2) :pretty t)
                      (format nil "[~%  1,~%  2~%]"))
            :to-be-truthy)))

(it "round-trips parse and stringify for a nested value"
  (let* ((original "{\"name\":\"a\",\"nums\":[1,2,3],\"ok\":true}")
         (value (parse original :object-type :alist :array-type :list :key-type :string))
         (again (stringify (alist->json-object value))))
    (expect (string= (stringify (cdr (assoc "nums" value :test #'string=))) "[1,2,3]")
            :to-be-truthy)
    (expect (search "\"name\":\"a\"" again) :to-be-truthy)))
