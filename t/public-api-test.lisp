;;;; t/public-api-test.lisp
;;;;
;;;; The public API is the thing this library's version number makes promises
;;;; about, so it is pinned here rather than left implicit in src/package.lisp.
;;;; A symbol appearing or disappearing fails these specs, which forces the
;;;; addition or removal to be a deliberate, semver-classified decision instead
;;;; of an accident of editing an export list.
(in-package #:cl-json-kit/test)

(defparameter +public-api+
  '(;; Reading
    "PARSE" "PARSE-PREFIX" "READ-JSON"
    ;; Writing
    "WRITE-JSON" "STRINGIFY"
    ;; Opaque JSON null / false
    "+JSON-NULL+" "+JSON-FALSE+" "JSON-NULL-P" "JSON-FALSE-P"
    ;; Parse diagnostics
    "JSON-PARSE-ERROR"
    "JSON-PARSE-ERROR-POSITION" "JSON-PARSE-ERROR-LINE" "JSON-PARSE-ERROR-COLUMN"
    "JSON-PARSE-ERROR-PATH" "JSON-PARSE-ERROR-EXPECTED" "JSON-PARSE-ERROR-CONTEXT"
    "JSON-PARSE-ERROR-TEXT"
    ;; Serialization diagnostics
    "JSON-SERIALIZATION-ERROR"
    "JSON-SERIALIZATION-ERROR-MESSAGE" "JSON-SERIALIZATION-ERROR-PATH"
    ;; Explicit alist <-> ordered-object bridges
    "MAKE-JSON-OBJECT" "JSON-OBJECT-P" "JSON-OBJECT-MEMBERS"
    "ALIST->JSON-OBJECT" "JSON-OBJECT->ALIST")
  "Every symbol the JSON-KIT package exports, as of the 1.0 compatibility
promise in docs/src/compatibility.md.")

(defun external-symbol-names ()
  (let ((names '()))
    (do-external-symbols (symbol (find-package "JSON-KIT"))
      (push (symbol-name symbol) names))
    names))

(defun documented-p (symbol)
  "True when SYMBOL carries a docstring in every role it actually fills, so that
DOCUMENTATION answers at the REPL for the whole exported surface."
  (let ((roles '()))
    (when (fboundp symbol)
      (push (documentation symbol 'function) roles))
    (when (boundp symbol)
      (push (documentation symbol 'variable) roles))
    (when (find-class symbol nil)
      (push (documentation symbol 'type) roles))
    (and roles (every #'identity roles))))

(describe "public API surface"
  (it "exports exactly the symbols covered by the compatibility promise"
    (let ((actual (sort (external-symbol-names) #'string<))
          (expected (sort (copy-list +public-api+) #'string<)))
      (with-soft-assertions
        (expect (set-difference actual expected :test #'string=) :to-equal '())
        (expect (set-difference expected actual :test #'string=) :to-equal '())
        (expect actual :to-equal expected))))

  (it "documents every exported symbol"
    (with-soft-assertions
      (dolist (name (sort (external-symbol-names) #'string<))
        (let ((symbol (find-symbol name "JSON-KIT")))
          (expect (list name (and (documented-p symbol) t))
                  :to-equal (list name t))))))

  (it "keeps the package's only nickname-free name stable"
    ;; Callers write JSON-KIT:PARSE; renaming or nicknaming the package would
    ;; break every one of them just as surely as removing a symbol would.
    (expect (package-name (find-package "JSON-KIT")) :to-equal "JSON-KIT")
    (expect (package-nicknames (find-package "JSON-KIT")) :to-equal '())))
