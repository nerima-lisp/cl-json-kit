;;;; src/data.lisp
;;;;
;;;; The data layer: type definitions and constant tables shared by the reader
;;;; and the writer.  Deliberately free of behaviour -- every function that
;;;; *acts* on these types lives in a logic file (reader-*, writer-*,
;;;; conversion).  Keeping the shapes here means the reader and writer agree on
;;;; one definition of "a JSON null", "a JSON false", and "an ordered object"
;;;; instead of each inventing its own.
(in-package #:json-kit)

;;; ---------------------------------------------------------------------
;;; Opaque sentinels for JSON `null` and `false`
;;; ---------------------------------------------------------------------
;;; These are distinct boxed objects rather than NIL/keywords so that a parsed
;;; `null` can never be confused with an empty array, an absent hash entry, or
;;; a user's own :NULL keyword.  Callers must test them with JSON-NULL-P /
;;; JSON-FALSE-P and never depend on their printed form or type.
(defstruct (json-sentinel
            (:constructor make-json-sentinel (name))
            (:copier nil)
            (:predicate nil))
  (name nil :read-only t))

(defvar +json-null+ (make-json-sentinel :null)
  "Opaque value the reader returns for JSON `null` by default.")

(defvar +json-false+ (make-json-sentinel :false)
  "Opaque value the reader returns for JSON `false` by default.")

(declaim (inline json-null-p json-false-p))

(defun json-null-p (value)
  "True when VALUE is the opaque JSON null sentinel."
  (eq value +json-null+))

(defun json-false-p (value)
  "True when VALUE is the opaque JSON false sentinel."
  (eq value +json-false+))

;;; ---------------------------------------------------------------------
;;; Ordered JSON object
;;; ---------------------------------------------------------------------
;;; A HASH-TABLE loses key order and duplicates; when a caller needs to write
;;; those out faithfully (e.g. round-tripping) they hold the members in this
;;; opaque ordered structure instead.  Built only through MAKE-JSON-OBJECT /
;;; ALIST->JSON-OBJECT (see conversion.lisp).
(defstruct (json-object
            (:constructor %make-json-object (members))
            (:copier nil)
            (:conc-name %json-object-))
  (members nil :type list :read-only t))

;;; ---------------------------------------------------------------------
;;; Canonical two-character string escapes
;;; ---------------------------------------------------------------------
;;; The single source of truth for JSON's short escape sequences.  The reader
;;; (decode: letter -> character) and the writer (encode: character -> letter)
;;; both derive their dispatch from this table via macros in macros.lisp, so
;;; the two directions can never drift apart.  `"`, `\`, `/` and `\uXXXX` are
;;; handled separately because they are not simple letter<->character pairs.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (defparameter +json-short-escapes+
    '((#\Backspace . #\b)
      (#\Page      . #\f)
      (#\Newline   . #\n)
      (#\Return    . #\r)
      (#\Tab       . #\t))
    "Alist mapping an unescaped character to its JSON escape letter."))

;;; ---------------------------------------------------------------------
;;; Number-grammar character vocabularies
;;; ---------------------------------------------------------------------
;;; RFC 8259's number grammar has exactly one sign alphabet and one exponent
;;; marker alphabet, each read in more than one place (scanning a number's
;;; grammar, decoding its exponent, and framing one number out of a live
;;; character stream); naming them here means every site tests against the
;;; same two characters instead of repeating the literal.
(defparameter +json-sign-characters+ '(#\+ #\-)
  "The two characters that may prefix a JSON number's exponent.")

(defparameter +json-exponent-markers+ '(#\e #\E)
  "The two characters that introduce a JSON number's exponent.")
