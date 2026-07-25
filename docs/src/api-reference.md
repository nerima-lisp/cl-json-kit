# API Reference

Everything a caller needs is exported from the single `json-kit` package:
the two reading entry points, the two writing entry points, the opaque
`null` / `false` sentinels and their predicates, the structured conditions, and
the explicit alist ↔ object bridges. Nothing else is exported.

This page is a compact index. Each entry links to the guide section with
examples and the full discussion.

## Reading

### `parse`

```lisp
(json-kit:parse string &key object-type array-type duplicate-key-policy
                            null-value false-value true-value
                            key-decoder number-decoder object-hook array-hook
                            max-depth max-input-length max-string-length
                            max-number-length max-exact-exponent
                            max-array-elements max-object-members
                            context timeout-seconds)
  => value
```

Parse the whole string as exactly one JSON value, rejecting trailing data.
→ [Reading JSON](reading.md#parse)

### `parse-prefix`

```lisp
(json-kit:parse-prefix string &rest options)   ; also accepts :index
  => value, end-index
```

Parse the first value at or after `:index` and return it plus the exclusive end
index. → [Reading JSON](reading.md#parse-prefix)

### `read-json`

```lisp
(json-kit:read-json stream &rest parse-options)
  => value
```

Read exactly one JSON value from a character stream, leaving the following
character unread. → [Reading JSON](reading.md#read-json)

## Writing

### `stringify`

```lisp
(json-kit:stringify value &key pretty indent max-depth max-output-length
                               max-elements sort-keys
                               null-value false-value number-encoder)
  => string
```

Serialize a value to a JSON string. → [Writing JSON](writing.md#stringify)

### `write-json`

```lisp
(json-kit:write-json value stream
                     &key pretty indent max-depth max-elements
                          max-output-length sort-keys
                          null-value false-value number-encoder)
  => value
```

Write a value to an existing character stream and return the original value.
→ [Writing JSON](writing.md#write-json)

## Sentinels

| Symbol | Kind | Meaning |
| --- | --- | --- |
| `+json-null+` | variable | Opaque marker for JSON `null`. |
| `+json-false+` | variable | Opaque marker for JSON `false`. |
| `json-null-p` | function | True iff its argument is the null sentinel. |
| `json-false-p` | function | True iff its argument is the false sentinel. |

Both markers are special variables (defined with `defvar`), not constants —
their identity is what matters, so test them with the predicates rather than
depending on their value, printed form, or type.

Test these values with the predicates; do not depend on their printed form or
implementation type. → [Data Model and Mapping](data-model.md#opaque-null-and-false)

## Parse diagnostics

| Symbol | Kind | Meaning |
| --- | --- | --- |
| `json-parse-error` | condition | Signalled for malformed input (subtype of `error`). |
| `json-parse-error-position` | reader | Zero-based character offset. |
| `json-parse-error-line` | reader | One-based line. |
| `json-parse-error-column` | reader | One-based column. |
| `json-parse-error-path` | reader | Path of keys and indices to the failure. |
| `json-parse-error-expected` | reader | Short description of what was expected. |
| `json-parse-error-context` | reader | The `:context` label. |
| `json-parse-error-text` | function | Bounded, sanitized snippet of the input. |

→ [Error Handling](error-handling.md#parse-errors)

## Serialization diagnostics

| Symbol | Kind | Meaning |
| --- | --- | --- |
| `json-serialization-error` | condition | Signalled for unsupported output (subtype of `error`). |
| `json-serialization-error-message` | reader | Bounded failure description. |
| `json-serialization-error-path` | reader | Path to the offending value. |

→ [Error Handling](error-handling.md#serialization-errors)

## Ordered-object bridges

| Symbol | Kind | Meaning |
| --- | --- | --- |
| `make-json-object` | function | Build an ordered object from `(key . value)` members. |
| `json-object-p` | function | Identify a `json-object`. |
| `json-object-members` | function | Return an ordered object's alist of members. |
| `alist->json-object` | function | Validate an alist and convert it to an object. |
| `json-object->alist` | function | Convert an object, hash table, or alist to an alist. |

→ [Conversion Helpers](conversion.md)

## Default option values

For convenience, the defaults enforced by the entry points:

| Option | Default | Applies to |
| --- | --- | --- |
| `object-type` | `:hash-table` | `parse`, `parse-prefix`, `read-json` |
| `array-type` | `:vector` | `parse`, `parse-prefix`, `read-json` |
| `duplicate-key-policy` | `:last` | reading |
| `null-value` | `+json-null+` | reading, writing |
| `false-value` | `+json-false+` | reading, writing |
| `true-value` | `t` | reading |
| `max-depth` | `512` | reading, writing |
| `max-input-length` | `16777216` | reading |
| `max-string-length` | `1048576` | reading |
| `max-number-length` | `1024` | reading |
| `max-exact-exponent` | `10000` | reading |
| `max-array-elements` | `1000000` | reading |
| `max-object-members` | `1000000` | reading |
| `max-elements` | `1000000` | writing |
| `max-output-length` | `16777216` | writing |
| `indent` | `2` | writing |
| `sort-keys` | `nil` | writing |
| `context` | `"json"` | reading |
| `max-elements` (conversion) | `1000000` | conversion helpers |

See [Resource Limits and Security](security.md) for the semantics of each
bound.
