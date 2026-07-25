# Writing JSON

`cl-json-kit` offers two writer entry points that share the same options:

- [`stringify`](#stringify) — returns a JSON string.
- [`write-json`](#write-json) — writes characters to an existing stream.

Both dispatch **purely by Lisp type**: hash tables become objects, and vectors
and proper lists become arrays. The writer never infers a cons list's intended
JSON shape from its structure — see [Data Model and Mapping](data-model.md).

## `stringify`

```lisp
(json-kit:stringify value
  &key
    pretty
    (indent 2)
    (max-depth 512)
    (max-output-length 16777216)
    (max-elements 1000000)
    (sort-keys nil)
    (null-value json-kit:+json-null+)
    (false-value json-kit:+json-false+)
    number-encoder)
```

```lisp
(json-kit:stringify #(1 2 3))          ; => "[1,2,3]"
(json-kit:stringify "abc")             ; => "\"abc\""
```

## `write-json`

```lisp
(json-kit:write-json value stream
  &key
    pretty
    (indent 2)
    (max-depth 512)
    (max-elements 1000000)
    (max-output-length 16777216)
    (sort-keys nil)
    (null-value json-kit:+json-null+)
    (false-value json-kit:+json-false+)
    number-encoder)
```

`write-json` writes characters to an existing stream, leaves it open, and
returns the **original value**. `stringify` is the string-returning wrapper
around the same machinery; both honor the `max-output-length` character-count
limit.

```lisp
(with-open-file (out "result.json"
                     :direction :output
                     :if-exists :supersede
                     :element-type 'character)
  (json-kit:write-json #(1 2 3) out))
```

!!! warning "Stream output is incremental, not transactional"
    If serialization signals an error partway through, an already-written
    prefix can remain in the stream. Use `stringify` (and write the returned
    string only on success) when you need all-or-nothing output.

## Deterministic ordering with `sort-keys`

Hash-table iteration order is unspecified. When `:sort-keys` is true, object
members are sorted lexicographically by their string keys, giving deterministic
output suited to tests, diffs, and caching:

```lisp
(let ((table (make-hash-table :test #'equal)))
  (setf (gethash "b" table) 2
        (gethash "a" table) 1)
  (json-kit:stringify table :sort-keys t))
;; => "{\"a\":1,\"b\":2}"
```

!!! note "Deterministic, not RFC 8785 canonical"
    `:sort-keys t` gives deterministic *member ordering*, not RFC 8785
    canonical JSON and not a cross-implementation byte-for-byte guarantee. The
    writer does not implement RFC 8785 number canonicalization. See
    [RFC 8259 Scope](rfc-8259.md).

## Pretty printing

`:pretty t` adds newlines and indents nested levels by `:indent` spaces
(default `2`):

```lisp
(json-kit:stringify #(1 (2 3)) :pretty t)
;; =>
;; [
;;   1,
;;   [
;;     2,
;;     3
;;   ]
;; ]
```

## `number-encoder`

`:number-encoder` overrides the formatting of supported numbers. It receives a
Lisp number and must return a string matching the JSON number grammar. It can
provide representations for non-terminating ratios, but **non-finite floats
remain unacceptable**.

```lisp
(json-kit:stringify 1/8)                               ; => "0.125"
;; (json-kit:stringify 1/3) signals JSON-SERIALIZATION-ERROR
(json-kit:stringify 1/3 :number-encoder (constantly "0.333"))
;; => "0.333"
```

The built-in writer preserves negative floating-point zero and emits exact
decimal text for terminating ratios (denominators with only 2 and 5 as prime
factors).

## Sentinels

`:null-value` and `:false-value` tell the writer which Lisp values to emit as
JSON `null` and `false`. They default to `+json-null+` and `+json-false+`, so
values produced by the reader round-trip without configuration. Override them
to match a representation your application already uses.

## Resource limits

`:max-depth`, `:max-elements`, and `:max-output-length` bound recursion,
aggregate size, and emitted length. Their semantics and defaults are on
[Resource Limits and Security](security.md).

```lisp
(json-kit:stringify "abc" :max-output-length 5)  ; => "\"abc\""
(json-kit:stringify "abc" :max-output-length 4)  ; signals a serialization error
```

## Non-ASCII output

The writer emits non-ASCII Lisp characters directly and escapes only the JSON
characters that must be escaped; it does **not** promise ASCII-only output. If
you need ASCII-only bytes, encode the resulting characters through an
ASCII-with-escapes layer of your own, or configure your output stream's
external format accordingly.
