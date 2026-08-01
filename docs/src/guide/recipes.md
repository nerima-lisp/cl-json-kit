# Recipes

Practical patterns that combine the reader, writer, and helpers. Each recipe is
self-contained and uses only exported symbols. For the full option lists, see
[Reading JSON](reading.md) and [Writing JSON](writing.md).

## Round-trip a document unchanged

Parse and re-serialize, keeping member order stable:

```lisp
(let ((value (json-kit:parse input)))
  (json-kit:stringify value :sort-keys t))
```

`:sort-keys t` makes the output deterministic even though hash-table iteration
order is not. To preserve the *original* member order instead of sorting, parse
to an ordered object:

```lisp
(let* ((members (json-kit:parse input
                  :object-type :alist
                  :duplicate-key-policy :preserve))
       (object (json-kit:alist->json-object members
                 :duplicate-key-policy :preserve)))
  (json-kit:stringify object))
```

## Read newline-delimited JSON (NDJSON)

`read-json` frames exactly one value and leaves the following character
unread — it does *not* consume trailing whitespace and does *not* signal
`end-of-file` at the end of the stream. So detect the end yourself with
`peek-char`, which skips whitespace and returns your sentinel at EOF, then read
one value per iteration:

```lisp
(defun read-all-json (stream)
  "Read every whitespace-separated JSON value from STREAM into a list."
  (loop while (peek-char t stream nil nil)   ; skip whitespace; NIL at EOF
        collect (json-kit:read-json stream)))

(with-input-from-string (in (format nil "1~%2~%[3,4]~%"))
  (read-all-json in))
;; => (1 2 #(3 4))
```

For back-to-back values in a *string* (rather than a stream), use
[`parse-prefix`](reading.md#parse-prefix): it returns the exclusive end index of
the value it read, without consuming trailing whitespace, so skip any
whitespace before advancing:

```lisp
(defun parse-all-prefix (string)
  (loop with index = 0
        with length = (length string)
        do (loop while (and (< index length)
                            (member (char string index)
                                    '(#\Space #\Tab #\Newline #\Return)))
                 do (incf index))
        while (< index length)
        collect (multiple-value-bind (value end)
                    (json-kit:parse-prefix string :index index)
                  (setf index end)
                  value)))

(parse-all-prefix "1 2 [3,4] ")
;; => (1 2 #(3 4))
```

## Map JSON `null` to your own marker

Override the value the reader produces so `null` becomes whatever your
application already uses — for example, `:null`:

```lisp
(json-kit:parse "[null,1,null]" :null-value :null :array-type :list)
;; => (:NULL 1 :NULL)
```

When writing such values back, tell the writer which Lisp value means `null`:

```lisp
(json-kit:stringify (list :null 1) :null-value :null)
;; => "[null,1]"
```

## Normalize object keys

Object keys are **always strings**. `:key-decoder` transforms the decoded
string but must itself return a string — the parser rejects a non-string
result. Use it to normalize keys, for example by case-folding:

```lisp
(json-kit:parse "{\"X-Id\":1,\"Name\":\"Ada\"}"
                :object-type :alist
                :key-decoder #'string-downcase)
;; => (("x-id" . 1) ("name" . "Ada"))
```

This keeps duplicate detection meaningful, since duplicates are compared
*after* `key-decoder` runs.

## Convert object keys to keywords

Because keys stay strings, keyword keys are produced by an explicit
post-processing step rather than by `key-decoder`. `:object-hook` receives each
completed object and its return value replaces it, so rebuild the members with
keyword keys there:

```lisp
(json-kit:parse "{\"name\":\"Ada\",\"age\":37}"
                :object-type :alist
                :object-hook
                (lambda (members)
                  (mapcar (lambda (pair)
                            (cons (intern (string-upcase (car pair)) :keyword)
                                  (cdr pair)))
                          members)))
;; => ((:NAME . "Ada") (:AGE . 37))
```

!!! warning "Interning untrusted keys is a resource risk"
    `intern` on attacker-controlled strings grows the keyword package without
    bound. For untrusted input, map through a fixed table of allowed keys and
    reject or ignore the rest, rather than interning arbitrarily.

## Decode numbers to a custom type

Supply a `:number-decoder` to keep the original token, parse to a rational, or
build a decimal type. It receives the token and whether it had integer syntax:

```lisp
;; Keep every number as its exact source token.
(json-kit:parse "[1, 2.5, 1e3]"
                :array-type :list
                :number-decoder (lambda (token integer-p)
                                  (declare (ignore integer-p))
                                  token))
;; => ("1" "2.5" "1e3")
```

## Encode ratios the built-in writer rejects

The writer emits a ratio only when it has an exact finite decimal
representation. Provide a `:number-encoder` for the rest:

```lisp
(json-kit:stringify 1/8)   ; => "0.125"  (exact, no encoder needed)

(json-kit:stringify 1/3
  :number-encoder (lambda (n)
                    (format nil "~,6F" (coerce n 'double-float))))
;; => "0.333333"
```

The encoder must return a string matching the JSON number grammar; non-finite
floats remain unacceptable regardless.

## Serialize an alist as a JSON object

A plain list is always a JSON array. Convert explicitly to get an object:

```lisp
(json-kit:stringify
 (json-kit:alist->json-object (list (cons "a" 1) (cons "b" 2)))
 :sort-keys t)
;; => "{\"a\":1,\"b\":2}"
```

## Bound untrusted input tightly

The defaults are generic; tighten them for a public endpoint:

```lisp
(json-kit:parse request-body
                :context "request body"
                :max-input-length 65536
                :max-depth 32
                :max-array-elements 10000
                :max-object-members 10000
                :timeout-seconds 2)   ; wall-clock guard on SBCL
```

See [Resource Limits and Security](../reference/resource-limits.md) for each bound.

## Strip a UTF-8 BOM before parsing

The reader treats a leading `U+FEFF` byte-order mark as an unexpected
character, not whitespace — it is not part of the JSON grammar (see
[RFC 8259 Scope](../reference/rfc-8259.md#what-the-reader-rejects)). Files written by some
editors and spreadsheet exporters include one, so strip it before parsing text
read from an untrusted file:

```lisp
(defun strip-utf-8-bom (string)
  "Remove a single leading U+FEFF byte-order mark from STRING, if present."
  (if (and (plusp (length string)) (char= (char string 0) (code-char #xFEFF)))
      (subseq string 1)
      string))

(json-kit:parse (strip-utf-8-bom (uiop:read-file-string "input.json")))
```

If you decode the file yourself via a stream instead of a string, `peek-char`
and discard a leading character `(eql (code-char #xFEFF))` before calling
`read-json` the same way.

## Report a parse error with coordinates

Turn a signalled condition into a structured, user-facing diagnostic:

```lisp
(handler-case
    (json-kit:parse maybe-bad :context "config file")
  (json-kit:json-parse-error (c)
    (format nil "~A at line ~D column ~D (path ~S): expected ~A"
            (json-kit:json-parse-error-context c)
            (json-kit:json-parse-error-line c)
            (json-kit:json-parse-error-column c)
            (json-kit:json-parse-error-path c)
            (json-kit:json-parse-error-expected c))))
```

See [Error Handling](../reference/conditions.md) for every accessor.
