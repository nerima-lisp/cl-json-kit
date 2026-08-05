;;;; t/conditions-test.lisp
;;;;
;;;; The bounded-diagnostic helpers in src/conditions.lisp are shared by both
;;;; condition types but only reachable indirectly through PARSE/STRINGIFY
;;;; call sites elsewhere in the suite, which never happen to overrun a bound.
;;;; These specs exercise the truncation and cycle-safety guarantees directly,
;;;; through BOUNDED-JSON-PARSE-ERROR/BOUNDED-JSON-SERIALIZATION-ERROR -- the
;;;; only place bounding happens now that it cannot live in an
;;;; INITIALIZE-INSTANCE :AFTER method (SBCL's condition classes never invoke
;;;; one, so raw MAKE-CONDITION deliberately does not bound anything).
(in-package #:cl-json-kit/test)

(describe "diagnostic snippet and path bounding"
  (it "truncates SAFE-DIAGNOSTIC-SNIPPET at exactly MAXIMUM-LENGTH characters"
    (let ((long (make-string 500 :initial-element #\a)))
      (with-soft-assertions
        (expect (= (length (json-kit::safe-diagnostic-snippet long 256)) 256) :to-be-truthy)
        (expect (string= (json-kit::safe-diagnostic-snippet long 256) (subseq long 0 256))
                :to-be-truthy))))

  (it "stops SAFE-DIAGNOSTIC-SNIPPET before splitting a multi-character escape"
    ;; Every character here escapes to a 6-character \\u00XX run; a maximum-length
    ;; that isn't a multiple of 6 must still stop on a whole escape, never mid-escape.
    (let* ((many (make-string 20 :initial-element (code-char 1)))
           (snippet (json-kit::safe-diagnostic-snippet many 10)))
      (with-soft-assertions
        (expect (<= (length snippet) 10) :to-be-truthy)
        (expect (zerop (mod (length snippet) 6)) :to-be-truthy))))

  (it "bounds BOUNDED-DIAGNOSTIC-PATH to MAXIMUM-ELEMENTS components"
    (let ((path (loop for index below 50 collect index)))
      (expect (= (length (json-kit::bounded-diagnostic-path path 32)) 32) :to-be-truthy)))

  (it "keeps BOUNDED-DIAGNOSTIC-PATH cycle-safe on a circular path"
    (let ((cycle (list 0 1 2)))
      (setf (cdddr cycle) cycle)
      (expect (equal (json-kit::bounded-diagnostic-path cycle 32) (list 0 1 2))
              :to-be-truthy)))

  (it "renders a character value through SAFE-DIAGNOSTIC-SNIPPET"
    (expect (string= (json-kit::safe-diagnostic-snippet #\a) "a") :to-be-truthy))

  (it "wraps a non-list BOUNDED-DIAGNOSTIC-PATH argument in a single-element list"
    (expect (equal (json-kit::bounded-diagnostic-path "not-a-list" 32) (list "not-a-list"))
            :to-be-truthy))

  (it "falls back to SAFE-DIAGNOSTIC-SNIPPET for an out-of-range integer path component"
    ;; A negative component fails the direct-collect range check
    ;; (0 <= component <= MOST-POSITIVE-FIXNUM), so it takes the same escaped-
    ;; rendering path as a string or symbol component instead of being
    ;; collected as a raw integer.
    (expect (equal (json-kit::bounded-diagnostic-path (list -1) 32) (list "-1"))
            :to-be-truthy)))

(describe "condition slot bounding at construction"
  (it "truncates an oversized JSON-PARSE-ERROR context, expected, and text"
    (let ((condition (json-kit::bounded-json-parse-error
                      :position 0 :line 1 :column 1
                      :context (make-string 500 :initial-element #\c)
                      :expected (make-string 500 :initial-element #\e)
                      :text (make-string 500 :initial-element #\t))))
      (with-soft-assertions
        (expect (= (length (json-parse-error-context condition)) 256) :to-be-truthy)
        (expect (= (length (json-parse-error-expected condition)) 128) :to-be-truthy)
        (expect (= (length (json-parse-error-text condition)) 256) :to-be-truthy))))

  (it "truncates an oversized JSON-SERIALIZATION-ERROR message and path"
    (let ((condition (json-kit::bounded-json-serialization-error
                      :message (make-string 500 :initial-element #\m)
                      :path (loop for index below 50 collect index))))
      (with-soft-assertions
        (expect (= (length (json-serialization-error-message condition)) 256) :to-be-truthy)
        (expect (= (length (json-serialization-error-path condition)) 32) :to-be-truthy))))

  (it "leaves a directly MAKE-CONDITIONed instance unbounded, unlike the BOUNDED-* constructors"
    ;; Documents the SBCL gotcha this file exists to guard against: nothing
    ;; about DEFINE-CONDITION bounds a raw MAKE-CONDITION call, which is why
    ;; every construction site in src/ goes through BOUNDED-JSON-PARSE-ERROR /
    ;; BOUNDED-JSON-SERIALIZATION-ERROR instead of ERROR with a type name.
    (let ((condition (make-condition 'json-parse-error
                                     :position 0 :line 1 :column 1
                                     :context (make-string 500 :initial-element #\c))))
      (expect (= (length (json-parse-error-context condition)) 500) :to-be-truthy))))
