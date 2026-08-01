# Conditions

`cl-json-kit` signals **typed conditions** with structured, machine-readable
slots. Diagnostic context, paths, and snippets are bounded, so an error report
never itself becomes a way to echo an unbounded amount of untrusted data.

## Parse errors

Malformed input signals `json-parse-error`. Its public readers are:

| Reader | Meaning |
| --- | --- |
| `json-parse-error-position` | Zero-based character offset. |
| `json-parse-error-line` | One-based line number. |
| `json-parse-error-column` | One-based column number. |
| `json-parse-error-path` | Path of object keys and array indices to the failure. |
| `json-parse-error-expected` | Short description of what was expected. |
| `json-parse-error-context` | The `:context` label supplied to the reader. |
| `json-parse-error-text` | A bounded, sanitized snippet of the offending input. |

```lisp
(handler-case
    (json-kit:parse "{\"items\":[0,]}" :context "request body")
  (json-kit:json-parse-error (condition)
    (list :line     (json-kit:json-parse-error-line condition)
          :column   (json-kit:json-parse-error-column condition)
          :path     (json-kit:json-parse-error-path condition)
          :expected (json-kit:json-parse-error-expected condition))))
```

The condition's `print-object` report combines these into a human-readable
line. For the input above — a trailing comma inside the array — the report is:

```text
request body parse error at line 1, column 13 (position 12) at ("items"): expected array value
```

### The error path

`json-parse-error-path` is a list that walks from the document root to the
point of failure. String components are object keys; nonnegative integers are
array indices. When the failure is *inside* an array element, the index appears
in the path:

```lisp
(handler-case
    (json-kit:parse "{\"items\":[1,2,x]}")
  (json-kit:json-parse-error (c)
    (values (json-kit:json-parse-error-path c)
            (json-kit:json-parse-error-expected c))))
;; => ("items" 2), "JSON value"
```

Here `("items" 2)` means *the element at index 2 of the array under key
`"items"`*, where the invalid token `x` begins. The path is bounded to a small
number of components and each component is escaped.

## Serialization errors

Serialization failures signal `json-serialization-error`, with:

| Reader | Meaning |
| --- | --- |
| `json-serialization-error-message` | A bounded description of the failure. |
| `json-serialization-error-path` | Path to the offending value. |

```lisp
(handler-case
    (json-kit:stringify (list (cons 1 2)))
  (json-kit:json-serialization-error (condition)
    (list :message (json-kit:json-serialization-error-message condition)
          :path    (json-kit:json-serialization-error-path condition))))
```

Common triggers include non-finite floats, ratios without an exact finite
decimal representation (absent a `:number-encoder`), dotted or circular lists,
circular aggregates, raw surrogate code points, non-string object keys, and
exceeding `:max-output-length`, `:max-depth`, or `:max-elements`. See
[Data Model and Mapping](../guide/data-model.md#unsupported-writer-inputs).

## Bounded diagnostics as a security property

Every attacker-influenced string, path component, and expected-value
description is **truncated and escaped exactly once**, at condition
construction, before it reaches a condition slot. Control characters are
escaped, snippets are capped (256 characters for text, shorter for paths and
expected values), and paths are limited in length and made cycle-safe.

This means you can log or surface a `json-parse-error` without worrying that a
crafted input has smuggled control characters, an enormous string, or a cyclic
structure into your logs. The bound is part of the library's
[security posture](resource-limits.md), not just a cosmetic nicety.

## Catching both condition types

Both conditions are subtypes of `error`, so ordinary `handler-case` /
`handler-bind` clauses apply. To treat any JSON failure uniformly:

```lisp
(handler-case
    (process (json-kit:parse input))
  (json-kit:json-parse-error (c)
    (report-bad-input c))
  (json-kit:json-serialization-error (c)
    (report-bad-output c)))
```
