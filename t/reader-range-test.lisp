;;;; t/reader-range-test.lisp
(in-package #:cl-json-kit/test)

(describe "parse ranges"
  (it "accepts zero start and the exclusive string end"
    (expect (parse "null" :start 0 :end 4) :to-satisfy #'json-null-p)
    (expect (parse "1" :end nil) :to-be 1))

  (it "parses only the selected range and defaults END to the string length"
    (expect (parse "bad[1,2]tail" :start 3 :end 8) :to-equalp #(1 2))
    (expect (parse "badtrue" :start 3) :to-be t)
    (expect (parse "x 1 y" :start 1 :end 4) :to-be 1))

  (it "does not read a token or collection beyond END"
    (expect (parse "123" :end 1) :to-be 1)
    (dolist (case '(("true" 3) ("[1]" 2) ("\"a\"" 2) ("1e2" 2)))
      (signals json-parse-error (parse (first case) :end (second case)))))

  (it "rejects out-of-range, reversed, and noninteger bounds"
    (dolist (options '((:start -1) (:start 5) (:start 1/2) (:start nil)
                       (:end -1) (:end 5) (:end 1/2) (:end "4")
                       (:start 3 :end 2)))
      (signals json-parse-error (apply #'parse "null" options))))

  (it "rejects empty ranges at zero, inside, and at the string end"
    (dolist (index '(0 2 4))
      (signals json-parse-error (parse "null" :start index :end index)))
    (signals json-parse-error (parse "" :start 0 :end 0)))

  (it "rejects extra values inside the selected range"
    (signals json-parse-error (parse "x1 2y" :start 1 :end 4)))

  (it "keeps error positions and line coordinates relative to the original string"
    (let ((condition (capture-json-parse-error
                      (parse (format nil "ignored~%[0,?]tail") :start 8 :end 13))))
      (expect (json-parse-error-position condition) :to-be 11)
      (expect (json-parse-error-line condition) :to-be 2)
      (expect (json-parse-error-column condition) :to-be 4)
      (expect (json-parse-error-path condition) :to-equal '(1))))

  (it "bounds MAX-INPUT-LENGTH by the selected range"
    (expect (parse "ignored1tail" :start 7 :end 8 :max-input-length 1) :to-be 1)
    (let ((condition (capture-json-parse-error
                      (parse "ignored12tail" :start 7 :end 9 :max-input-length 1))))
      (expect (json-parse-error-position condition) :to-be 8)))

  (it "forwards shape and scalar mapping options for ranges"
    (expect (parse "x[true]y" :start 1 :end 7 :array-type :list :true-value :yes)
            :to-equal '(:yes)))

  (it "preserves parse-prefix keyword and whole-input limit contracts"
    (signals json-parse-error (parse-prefix "1" :start 0))
    (signals json-parse-error (parse-prefix "1" :end 1))
    (signals json-parse-error (parse-prefix "xx1" :index 2 :max-input-length 1))))
