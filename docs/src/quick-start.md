# Quick Start

This page walks through the most common tasks. For the complete option lists,
see [Reading JSON](reading.md), [Writing JSON](writing.md), and the
[API Reference](api-reference.md).

## Parse a document

Object keys are strings by default, and objects become hash tables:

```lisp
(defparameter *document*
  (json-kit:parse
   "{\"name\":\"Ada\",\"active\":false,\"note\":null,\"tags\":[\"a\",\"b\"]}"))

(gethash "name" *document*)             ; => "Ada", T
```

JSON `false` and `null` are represented by opaque sentinels, **not** by Lisp
`nil`. Test them with predicates rather than by identity or printed form:

```lisp
(json-kit:json-false-p (gethash "active" *document*)) ; => T
(json-kit:json-null-p  (gethash "note"   *document*)) ; => T
```

## Choose the container shape

The reader never guesses; you select the container types explicitly.

```lisp
(json-kit:parse "[1,2,3]" :array-type :list)
;; => (1 2 3)

(json-kit:parse "{\"name\":\"Ada\"}" :object-type :alist)
;; => (("name" . "Ada"))
```

## Unicode and surrogate pairs

`\uXXXX` escapes decode UTF-16 surrogate pairs into a single character, so
non-BMP code points such as emoji round-trip correctly:

```lisp
(json-kit:parse "\"\\ud83d\\ude00\"")
;; => "😀"
```

## Write to a string

Hash tables become objects; vectors and proper lists become arrays.

```lisp
(let ((table (make-hash-table :test #'equal)))
  (setf (gethash "name" table) "Ada"
        (gethash "missing" table) json-kit:+json-null+)
  (json-kit:stringify table :sort-keys t))
;; => "{\"missing\":null,\"name\":\"Ada\"}"
```

`:sort-keys t` makes member ordering deterministic — useful for tests and
diffs. Without it, hash-table iteration order is unspecified.

## Write to a stream

`write-json` writes characters to an existing stream, leaves it open, and
returns the original value:

```lisp
(with-open-file (out "result.json"
                     :direction :output
                     :if-exists :supersede
                     :element-type 'character)
  (json-kit:write-json #(1 2 3) out))
```

## Scan concatenated values

`parse-prefix` reads the first value and returns the exclusive end index, so
you can walk a stream of back-to-back values:

```lisp
(multiple-value-list (json-kit:parse-prefix "  [1,2] next"))
;; => (#(1 2) 7)
```

## Handle errors

Malformed input signals a typed condition that carries source coordinates and
a path into the document:

```lisp
(handler-case
    (json-kit:parse "{\"items\":[0,]}" :context "request body")
  (json-kit:json-parse-error (condition)
    (list :line   (json-kit:json-parse-error-line condition)
          :column (json-kit:json-parse-error-column condition)
          :path   (json-kit:json-parse-error-path condition)
          :expected (json-kit:json-parse-error-expected condition))))
```

See [Error Handling](error-handling.md) for every reader on the condition
objects.

## Next steps

- [Data Model and Mapping](data-model.md) — exactly how each JSON and Lisp
  value is represented.
- [Reading JSON](reading.md) — every `parse` option, callbacks, and duplicate
  key policies.
- [Writing JSON](writing.md) — pretty printing, sorting, and number encoding.
- [Resource Limits and Security](security.md) — bounding untrusted input.
- [FAQ](faq.md) — thread safety, BOM handling, and other questions that come
  up past the basics.
