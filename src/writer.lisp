;;;; src/writer.lisp
;;;;
;;;; STRINGIFY dispatches purely on the Lisp TYPE of VALUE (see the TYPECASE
;;;; in WRITE-JSON-VALUE below).  In particular a HASH-TABLE always becomes a
;;;; JSON object and a (non-string) VECTOR or LIST always becomes a JSON
;;;; array; a plain cons-list is never inspected to see whether it "looks
;;;; like" an alist of key/value pairs.  Anyone who wants an ALIST written as
;;;; a JSON object must say so explicitly with ALIST->JSON-OBJECT first.

(in-package #:json-kit)

(defun write-json-string (s stream)
  (write-char #\" stream)
  (loop for c across s
        do (case c
             (#\" (write-string "\\\"" stream))
             (#\\ (write-string "\\\\" stream))
             (#\Newline (write-string "\\n" stream))
             (#\Tab (write-string "\\t" stream))
             (#\Return (write-string "\\r" stream))
             (#\Backspace (write-string "\\b" stream))
             (#\Page (write-string "\\f" stream))
             (t (if (< (char-code c) #x20)
                    (format stream "\\u~4,'0X" (char-code c))
                    (write-char c stream)))))
  (write-char #\" stream))

(defun write-json-number (value stream)
  (etypecase value
    (integer (format stream "~D" value))
    (float (write-string
            (let ((*read-default-float-format* 'double-float))
              (format nil "~F" (coerce value 'double-float)))
            stream))
    (rational (write-json-number (coerce value 'double-float) stream))))

(defun json-object-key-string (key)
  "Object keys must ultimately be JSON strings.  Both the raw strings
produced by PARSE with :KEY-TYPE :STRING and the keywords produced with
:KEY-TYPE :KEYWORD (or supplied directly by a caller) are accepted."
  (etypecase key
    (string key)
    (symbol (symbol-name key))))

(defun pretty-newline-indent (stream indent level)
  (write-char #\Newline stream)
  (dotimes (_ (* indent level))
    (write-char #\Space stream)))

(defun write-json-object-pairs (pairs stream pretty indent level)
  (write-char #\{ stream)
  (let ((child-level (1+ level))
        (first t))
    (dolist (pair pairs)
      (if first (setf first nil) (write-char #\, stream))
      (when pretty (pretty-newline-indent stream indent child-level))
      (write-json-string (json-object-key-string (car pair)) stream)
      (write-string (if pretty ": " ":") stream)
      (write-json-value (cdr pair) stream pretty indent child-level))
    (when (and pretty (not first))
      (pretty-newline-indent stream indent level)))
  (write-char #\} stream))

(defun write-json-array-from-vector (vector stream pretty indent level)
  (write-char #\[ stream)
  (let ((child-level (1+ level))
        (first t))
    (loop for element across vector
          do (if first (setf first nil) (write-char #\, stream))
             (when pretty (pretty-newline-indent stream indent child-level))
             (write-json-value element stream pretty indent child-level))
    (when (and pretty (not first))
      (pretty-newline-indent stream indent level)))
  (write-char #\] stream))

(defun write-json-array-from-list (list stream pretty indent level)
  "Walks LIST as a sequence of CONS cells.  A proper (NIL-terminated) list
writes each element in order.  An improper (dotted) list -- e.g. (CONS 1
2) -- writes its final non-NIL, non-CONS tail as one more array element
instead of signalling an error, so a plain cons-list is always serialized by
its cons structure alone and never mistaken for anything else."
  (write-char #\[ stream)
  (let ((child-level (1+ level))
        (first t)
        (rest list))
    (loop while (consp rest)
          do (if first (setf first nil) (write-char #\, stream))
             (when pretty (pretty-newline-indent stream indent child-level))
             (write-json-value (car rest) stream pretty indent child-level)
             (setf rest (cdr rest)))
    (when (and rest (not (null rest)))
      (if first (setf first nil) (write-char #\, stream))
      (when pretty (pretty-newline-indent stream indent child-level))
      (write-json-value rest stream pretty indent child-level))
    (when (and pretty (not first))
      (pretty-newline-indent stream indent level)))
  (write-char #\] stream))

(defun hash-table-pairs (table)
  (let ((pairs '()))
    (maphash (lambda (k v) (push (cons k v) pairs)) table)
    (nreverse pairs)))

(defun write-json-value (value stream pretty indent level)
  (typecase value
    (string (write-json-string value stream))
    (null (write-string "[]" stream))
    ((eql t) (write-string "true" stream))
    ((eql :false) (write-string "false" stream))
    ((eql :null) (write-string "null" stream))
    (hash-table (write-json-object-pairs (hash-table-pairs value) stream pretty indent level))
    (keyword (error "json-kit: cannot stringify keyword ~S (only :FALSE and :NULL are recognized boolean/null markers)" value))
    ((or integer float rational) (write-json-number value stream))
    (vector (write-json-array-from-vector value stream pretty indent level))
    (list (write-json-array-from-list value stream pretty indent level))
    (t (error "json-kit: cannot stringify value of type ~S" (type-of value)))))

(defun stringify (value &key pretty (indent 2))
  "Serialize VALUE to a JSON string.

Dispatch is purely by Lisp TYPE, never by inspecting the shape of a value:
a HASH-TABLE is always written as a JSON object; a (non-string) VECTOR or
LIST is always written as a JSON array, element by element, regardless of
whether its elements happen to be CONS cells.  In particular a plain list of
conses such as (LIST (CONS 1 2) (CONS 3 4)) is written as the array
[[1,2],[3,4]] -- STRINGIFY never guesses that such a list is \"really\" an
alist meant to become a JSON object.  If you want an ALIST serialized as a
JSON object, wrap it first with ALIST->JSON-OBJECT.

T is written as true, :FALSE as false, :NULL (and NIL, since NIL doubles as
the empty list) as null/[] respectively -- NIL always means the empty array,
never false, so there is no separate ambiguity between \"empty list\" and
\"false\".

Strings are escaped per the JSON grammar: \", \\, newline, tab, carriage
return, backspace, form feed, and any other control character below U+0020
(as \\u00XX).

When PRETTY is true, objects and arrays are indented by INDENT spaces per
nesting level (default 2)."
  (with-output-to-string (out)
    (write-json-value value out pretty indent 0)))
