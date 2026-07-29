;;;; t/reader-scalars-test.lisp
(in-package #:cl-json-kit/test)

(describe "reading scalars"
  (it "parses primitive tokens with opaque null/false defaults"
    (expect "\"hello\"" :to-parse-as "hello")
    (expect "42" :to-parse-as 42)
    (expect (parse "true") :to-be t)
    (expect (parse "false") :to-satisfy #'json-false-p)
    (expect (parse "null") :to-satisfy #'json-null-p)
    (expect (eq +json-null+ +json-false+) :to-be-falsy))

  (it "keeps 1.5 a double-float"
    (expect (parse "1.5") :to-be-type-of 'double-float))

  (it "honours explicit scalar mappings"
    (expect (parse "null" :null-value :missing) :to-be :missing)
    (expect (parse "false" :false-value nil) :to-be nil)
    (expect (parse "true" :true-value :yes) :to-be :yes)))

(describe "number grammar"
  (it-each (("0") ("-0") ("10") ("-12") ("0.5") ("1e2") ("1E-2") ("1e+2"))
      "accepts the JSON number ~S"
      (text)
    (expect (numberp (parse text)) :to-be-truthy))

  (it "keeps integer and floating prefix boundaries exact"
    (dolist (case (list (list "42 tail" 42 2)
                        (list "42.5 tail" 42.5d0 4)
                        (list "42e-1 tail" 4.2d0 5)
                        (list "9223372036854775808 tail" 9223372036854775808 19)))
      (destructuring-bind (text expected end) case
        (multiple-value-bind (value actual-end) (parse-prefix text)
          (expect value :to-be expected)
          (expect actual-end :to-be end))))
    (multiple-value-bind (value end) (parse-prefix "-0e+3 tail")
      (expect value :to-be-type-of (quote double-float))
      (expect (zerop value) :to-be-truthy)
      (expect (= (float-sign value) -1.0d0) :to-be-truthy)
      (expect end :to-be 5)))


  (it-each (("01") ("-01") ("+1") (".1") ("1.") ("1e") ("1e+") ("--1"))
      "rejects the malformed number ~S"
      (text)
    (signals json-parse-error (parse text)))

  (it-each ((#xFF11) (#x0661) (#x0967))
      "rejects the non-ASCII digit U+~4,'0X"
      (code)
    (let ((text (format nil "[~C]" (code-char code))))
      (signals json-parse-error (parse text))
      (with-input-from-string (stream text)
        (signals json-parse-error (read-json stream)))))

  (it "represents large and small magnitudes exactly within MAX-EXACT-EXPONENT"
    (let ((large (parse "1e400" :max-exact-exponent 400))
          (small (parse "1e-400" :max-exact-exponent 400))
          (negative-large (parse "-1e400" :max-exact-exponent 400))
          (negative-small (parse "-1e-400" :max-exact-exponent 400)))
      (expect (integerp large) :to-be-truthy)
      (expect (= large (expt 10 400)) :to-be-truthy)
      (expect (rationalp small) :to-be-truthy)
      (expect (= small (/ 1 (expt 10 400))) :to-be-truthy)
      (expect (= negative-large (- (expt 10 400))) :to-be-truthy)
      (expect (= negative-small (- (/ 1 (expt 10 400)))) :to-be-truthy)))

  (it-each (("1e401" 400) ("1e-401" 400) ("1e1000000000" 10000)
            ("1e-1000000000" 10000))
      "rejects the out-of-range scale ~S"
      (text limit)
    (signals json-parse-error (parse text :max-exact-exponent limit)))

  (it "rejects an enormous exponent literal but accepts leading-zero padding"
    (let ((huge (make-string 512 :initial-element #\9))
          (padded (make-string 512 :initial-element #\0)))
      (signals json-parse-error (parse (concatenate 'string "1e" huge)))
      (signals json-parse-error (parse (concatenate 'string "1e-" huge)))
      (expect (= (parse (concatenate 'string "1e" padded "1")) 10.0d0) :to-be-truthy)
      (let ((negative-zero (parse (concatenate 'string "-0e" huge))))
        (expect (zerop negative-zero) :to-be-truthy)
        (expect (= (float-sign negative-zero) -1.0d0) :to-be-truthy))))

  (it "treats zero coefficients with any exponent as signed float zero"
    (let ((positive (parse "0e10001"))
          (negative (parse "-0e10001")))
      (expect positive :to-be-type-of 'double-float)
      (expect (zerop positive) :to-be-truthy)
      (expect negative :to-be-type-of 'double-float)
      (expect (zerop negative) :to-be-truthy)
      (expect (= (float-sign negative) -1.0d0) :to-be-truthy)))
  (it "rounds decimal boundaries to the nearest double with ties to even"
    (expect (= (parse "1.00000000000000011102230246251565404236316680908203125")
               1.0d0)
            :to-be-truthy)
    (expect (= (parse "1.00000000000000011102230246251565404236316680908203126")
               1.0000000000000002d0)
            :to-be-truthy)
    (expect (= (parse "4.9406564584124654e-324") least-positive-double-float)
            :to-be-truthy)
    (expect (= (parse "2.2250738585072014e-308") least-positive-normalized-double-float)
            :to-be-truthy)
    (expect (= (parse "1.7976931348623157e308") most-positive-double-float)
            :to-be-truthy)
    (expect (= (parse "9007199254740993.0") 9007199254740992.0d0)
            :to-be-truthy)
    (expect (= (parse "9007199254740995.0") 9007199254740996.0d0)
            :to-be-truthy))
  (it "rounds ties on both sides of a binade boundary to even for both signs"
    (dolist (text (list "1.99999999999999988897769753748434595763683319091796875"
                        "2.0000000000000002220446049250313080847263336181640625"))
      (let ((positive (parse text))
            (negative (parse (concatenate (quote string) "-" text))))
        (expect positive :to-be-type-of (quote double-float))
        (expect negative :to-be-type-of (quote double-float))
        (expect (= (rational positive) 2) :to-be-truthy)
        (expect (= (rational negative) -2) :to-be-truthy))))
  (it "rounds the normal and subnormal boundary exactly for both signs"
    (labels ((dyadic-decimal (numerator denominator-exponent)
               (let* ((digits (write-to-string
                               (* numerator (expt 5 denominator-exponent))))
                      (padding (- denominator-exponent (length digits))))
                 (concatenate (quote string)
                              "0."
                              (make-string padding :initial-element #\0)
                              digits)))
             (expect-rational (text expected)
               (let ((actual (parse text :max-number-length 1200)))
                 (expect actual :to-be-type-of (quote double-float))
                 (expect (= (rational actual) expected) :to-be-truthy))))
      (let* ((max-subnormal-significand (1- (ash 1 52)))
             (min-normal-significand (ash 1 52))
             (boundary-midpoint-significand (1- (ash 1 53)))
             (max-subnormal (/ max-subnormal-significand (ash 1 1074)))
             (min-normal (/ min-normal-significand (ash 1 1074)))
             (boundary-midpoint (/ boundary-midpoint-significand (ash 1 1075)))
             (max-subnormal-text (dyadic-decimal max-subnormal-significand 1074))
             (min-normal-text (dyadic-decimal min-normal-significand 1074))
             (boundary-midpoint-text (dyadic-decimal boundary-midpoint-significand 1075)))
        (expect (= boundary-midpoint (/ (+ max-subnormal min-normal) 2)) :to-be-truthy)
        (expect-rational max-subnormal-text max-subnormal)
        (expect-rational min-normal-text min-normal)
        (expect-rational boundary-midpoint-text min-normal)
        (expect-rational
          (concatenate (quote string) "-" max-subnormal-text)
          (- max-subnormal))
        (expect-rational
          (concatenate (quote string) "-" min-normal-text)
          (- min-normal))
        (expect-rational
          (concatenate (quote string) "-" boundary-midpoint-text)
          (- min-normal)))))
  (it "falls back to exact rationals instead of infinity or a lost nonzero"
    (let ((overflow (parse "1.7976931348623159e308"))
          (underflow (parse "2.4703282292062327e-324")))
      (expect (rationalp overflow) :to-be-truthy)
      (expect (plusp overflow) :to-be-truthy)
      (expect (rationalp underflow) :to-be-truthy)
      (expect (plusp underflow) :to-be-truthy))
    (signals json-parse-error (parse "1e10001"))
    (signals json-parse-error (parse "1e-10001"))))
