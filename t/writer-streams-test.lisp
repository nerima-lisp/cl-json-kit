;;;; t/writer-streams-test.lisp
(in-package #:cl-json-kit/test)

(describe "output stream designators"
  (it "writes to a stream and returns the value"
    (let ((value #(1 2))
          (stream (make-string-output-stream)))
      (expect (eq (write-json value stream) value) :to-be-truthy)
      (expect (string= (get-output-stream-string stream) "[1,2]") :to-be-truthy)))

  (it "resolves and validates the STREAM argument"
    (let ((*standard-output* (make-string-output-stream)))
      (expect (eql (write-json 1 nil) 1) :to-be-truthy)
      (expect (string= (get-output-stream-string *standard-output*) "1") :to-be-truthy))
    (signals json-serialization-error (write-json 1 42))
    (let ((stream (make-string-input-stream "")))
      (unwind-protect (signals json-serialization-error (write-json 1 stream))
        (close stream)))
    (let ((stream (make-string-output-stream)))
      (close stream)
      (signals json-serialization-error (write-json 1 stream)))
    (let ((pathname (make-pathname :name (format nil "cl-json-kit-~A" (gensym)) :type "bin"
                                   :defaults (uiop:temporary-directory))))
      (unwind-protect
           (with-open-file (stream pathname :direction :output :element-type '(unsigned-byte 8)
                                            :if-exists :supersede :if-does-not-exist :create)
             (signals json-serialization-error (write-json 1 stream)))
        (when (probe-file pathname) (delete-file pathname))))))
