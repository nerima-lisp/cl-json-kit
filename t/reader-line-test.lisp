;;;; t/reader-line-test.lisp
(in-package #:cl-json-kit/test)

(describe "read-json-line"
  (it "reads one LF line without consuming the following line"
    (with-input-from-string (stream (format nil "[1]~%true~%"))
      (multiple-value-bind (value present-p) (read-json-line stream)
        (expect value :to-equalp #(1))
        (expect present-p :to-be t))
      (expect (peek-char nil stream) :to-be #\t)
      (expect (read-json-line stream) :to-be t)
      (expect (multiple-value-list (read-json-line stream)) :to-equal '(nil nil))))

  (it "consumes CRLF as one line terminator"
    (with-input-from-string (stream (format nil "1~C~C2~C~C" #\Return #\Newline
                                           #\Return #\Newline))
      (expect (read-json-line stream) :to-be 1)
      (expect (read-json-line stream) :to-be 2)
      (expect (multiple-value-list (read-json-line stream)) :to-equal '(nil nil))))

  (it "returns NIL NIL for EOF before any characters"
    (expect (multiple-value-list (read-json-line (make-string-input-stream "")))
            :to-equal '(nil nil)))

  (it "accepts a complete final line without a newline"
    (with-input-from-string (stream "null")
      (multiple-value-bind (value present-p) (read-json-line stream)
        (expect value :to-satisfy #'json-null-p)
        (expect present-p :to-be t))
      (expect (multiple-value-list (read-json-line stream)) :to-equal '(nil nil))))

  (it "distinguishes a mapped NIL value from EOF"
    (with-input-from-string (stream "true")
      (expect (multiple-value-list (read-json-line stream :true-value nil))
              :to-equal '(nil t))))

  (it "rejects empty and whitespace-only lines"
    (dolist (text (list (format nil "~%") (format nil "~C~C" #\Return #\Newline)
                       (format nil " ~C~%" #\Tab) " "))
      (signals json-parse-error (read-json-line (make-string-input-stream text)))))

  (it "rejects truncated JSON at EOF and does not borrow the following line"
    (dolist (text '("tru" "\"abc" "[1" "1e"))
      (signals json-parse-error (read-json-line (make-string-input-stream text))))
    (with-input-from-string (stream (format nil "[1~%]~%"))
      (signals json-parse-error (read-json-line stream))
      (expect (peek-char nil stream) :to-be #\])))

  (it "rejects two values on one line"
    (dolist (text (list "1 2" "true false" (format nil "{} []~%")))
      (signals json-parse-error (read-json-line (make-string-input-stream text)))))

  (it "treats a standalone CR as JSON whitespace within a line"
    (expect (read-json-line (make-string-input-stream (format nil "1~C" #\Return)))
            :to-be 1)
    (signals json-parse-error
      (read-json-line (make-string-input-stream (format nil "1~C2" #\Return)))))

  (it "bounds line content while excluding LF and CRLF terminators"
    (dolist (terminator (list (string #\Newline) (format nil "~C~C" #\Return #\Newline) ""))
      (expect (read-json-line (make-string-input-stream (concatenate 'string "1" terminator))
                              :max-input-length 1)
              :to-be 1))
    (signals json-parse-error
      (read-json-line (make-string-input-stream "12") :max-input-length 1)))

  (it "validates line limits, timeouts, and stream direction"
    (dolist (limit '(-1 "1"))
      (signals json-parse-error
        (read-json-line (make-string-input-stream "1") :max-input-length limit)))
    (signals json-parse-error
      (read-json-line (make-string-input-stream "1") :timeout-seconds -1))
    (signals json-parse-error (read-json-line "1"))
    (signals json-parse-error (read-json-line (make-string-output-stream)))
    (let ((path (merge-pathnames
                 (format nil "cl-json-kit-line-reader-~A.tmp" (gensym))
                 (uiop:temporary-directory))))
      (unwind-protect
           (progn
             (with-open-file (output path :direction :output :if-exists :supersede
                                          :element-type '(unsigned-byte 8))
               (write-byte 49 output))
             (with-open-file (input path :direction :input :element-type '(unsigned-byte 8))
               (signals json-parse-error (read-json-line input))))
        (ignore-errors (delete-file path)))))

  (it "forwards parsing options and rejects range options for stream readers"
    (expect (read-json-line (make-string-input-stream "[false]") :array-type :list
                            :false-value :no)
            :to-equal '(:no))
    (dolist (reader (list #'read-json #'read-json-line))
      (dolist (option '(:start :end))
        (signals json-parse-error
          (funcall reader (make-string-input-stream "1 2") option 1)))))

  #+sbcl
  (it "times out while waiting for the rest of a line"
      (:tags '(:slow))
    (let ((process (uiop:launch-program (list "sh" "-c" "printf '1'; sleep 5; printf '\\n'")
                                      :output :stream :error-output :stream)))
      (unwind-protect
           (expect (handler-case
                       (progn (read-json-line (uiop:process-info-output process)
                                              :timeout-seconds 0.2)
                              nil)
                     (sb-ext:timeout () t))
                   :to-be-truthy)
        (ignore-errors (uiop:terminate-process process :urgent t))
        (ignore-errors (uiop:wait-process process))))))
