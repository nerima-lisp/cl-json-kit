;;;; cl-json-kit.asd

;;; This form comes FIRST, before any defsystem. ASDF binds *package* to
;;; ASDF-USER only for a file it loads itself; read any other way -- a REPL
;;; `load`, an editor evaluating the buffer, flake.nix parsing :version -- the
;;; file is read in whatever package happens to be current. Saying it makes
;;; the file self-contained.
(in-package #:asdf-user)

(asdf:defsystem "cl-json-kit"
  :description "Dependency-free JSON reader and writer for Common Lisp
strings and character streams"
  :long-description "A JSON parser/serializer inspired by JavaScript's JSON.parse/JSON.stringify
and Python's json module.  Object/array shape is decided explicitly at parse time (never guessed
from the shape of a cons list afterwards), UTF-16 surrogate pairs in \\uXXXX escapes are decoded
correctly, and parsing can be bounded with a timeout."
  :author "takeokunn <bararararatty@gmail.com>"
  :maintainer "takeokunn <bararararatty@gmail.com>"
  :license "MIT"
  :version "1.2.0"
  :homepage "https://github.com/nerima-lisp/cl-json-kit"
  :bug-tracker "https://github.com/nerima-lisp/cl-json-kit/issues"
  :source-control (:git "https://github.com/nerima-lisp/cl-json-kit.git")
  :depends-on ()
  :pathname "src"
  :serial t
  :components ((:file "package")
               (:file "data")
               (:file "reader-macros")
               (:file "writer-macros")
               (:file "conditions")
               (:file "parser-state")
               (:file "reader-strings")
               (:file "reader-numbers")
               (:file "reader-collections")
               (:file "reader")
               (:file "reader-stream")
               (:file "writer-state")
               (:file "writer-strings")
               (:file "writer-numbers")
               (:file "writer-collections")
               (:file "writer")
               (:file "conversion"))
  :in-order-to ((test-op (test-op "cl-json-kit/test"))))

(asdf:defsystem "cl-json-kit/test"
  :description "Test system for cl-json-kit"
  :author "takeokunn <bararararatty@gmail.com>"
  :maintainer "takeokunn <bararararatty@gmail.com>"
  :license "MIT"
  :version "1.2.0"
  :homepage "https://github.com/nerima-lisp/cl-json-kit"
  :bug-tracker "https://github.com/nerima-lisp/cl-json-kit/issues"
  :source-control (:git "https://github.com/nerima-lisp/cl-json-kit.git")
  :depends-on ("cl-json-kit" "cl-weave")
  :pathname "t"
  :serial t
  :components ((:file "package")
               (:file "helpers-matchers")
               (:file "public-api-test")
               (:file "conditions-test")
               (:file "reader-scalars-test")
               (:file "reader-strings-test")
               (:file "reader-collections-test")
               (:file "reader-limits-test")
               (:file "reader-errors-test")
               (:file "reader-callbacks-test")
               (:file "reader-streaming-test")
               (:file "writer-numbers-test")
               (:file "writer-collections-test")
               (:file "writer-strings-test")
               (:file "writer-formatting-test")
               (:file "writer-limits-test")
               (:file "writer-streams-test")
               (:file "writer-alist-test")
               (:file "property-test")
               (:file "rfc8259-conformance-test"))
  :perform (test-op (operation component)
             (declare (ignore operation component))
             (unless (funcall (symbol-function (find-symbol "RUN-TESTS" "CL-JSON-KIT/TEST")))
               (error "cl-json-kit test suite failed"))))
