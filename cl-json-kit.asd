;;;; cl-json-kit.asd
(asdf:defsystem "cl-json-kit"
  :description "Dependency-free JSON reader and writer for Common Lisp strings and character streams"
  :long-description "A JSON parser/serializer inspired by JavaScript's JSON.parse/JSON.stringify
and Python's json module.  Object/array shape is decided explicitly at parse time (never guessed
from the shape of a cons list afterwards), UTF-16 surrogate pairs in \\uXXXX escapes are decoded
correctly, and parsing can be bounded with a timeout."
  :version "0.1.0"
  :author "takeokunn <bararararatty@gmail.com>"
  :maintainer "takeokunn <bararararatty@gmail.com>"
  :license "MIT"
  :homepage "https://github.com/nerima-lisp/cl-json-kit"
  :bug-tracker "https://github.com/nerima-lisp/cl-json-kit/issues"
  :source-control (:git "https://github.com/nerima-lisp/cl-json-kit.git")
  :depends-on ()
  :pathname "src"
  :serial t
  :components ((:file "package")
    (:file "conditions")
    (:file "reader")
    (:file "writer")
    (:file "conversion"))
  :in-order-to ((test-op (test-op "cl-json-kit/test"))))

(asdf:defsystem "cl-json-kit/test"
  :description "Test system for cl-json-kit"
  :version "0.1.0"
  :author "takeokunn <bararararatty@gmail.com>"
  :maintainer "takeokunn <bararararatty@gmail.com>"
  :license "MIT"
  :homepage "https://github.com/nerima-lisp/cl-json-kit"
  :bug-tracker "https://github.com/nerima-lisp/cl-json-kit/issues"
  :source-control (:git "https://github.com/nerima-lisp/cl-json-kit.git")
  :depends-on ("cl-json-kit" "cl-weave")
  :pathname "t"
  :serial t
  :components ((:file "package") (:file "reader-test") (:file "writer-test"))
  :perform (test-op (operation component) (declare (ignore operation component)) (unless (funcall (symbol-function (find-symbol "RUN-TESTS" "CL-JSON-KIT/TEST"))) (error "cl-json-kit test suite failed"))))
