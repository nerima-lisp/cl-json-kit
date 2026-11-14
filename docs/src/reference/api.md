# API Reference

The `json-kit` package exports the reading and writing entry points, the opaque
`null` / `false` sentinels and their predicates, the structured conditions, and
the explicit alist ↔ object bridges.

Each entry links to the corresponding guide section with examples and details.

## Reading

### `parse`

```lisp
(json-kit:parse string &key start end object-type array-type duplicate-key-policy
                            null-value false-value true-value
                            key-decoder number-decoder object-hook array-hook
                            max-depth max-input-length max-string-length
                            max-number-length max-exact-exponent
                            max-array-elements max-object-members
                            context timeout-seconds)
  => value
```

Parse the range from `:start` (default zero) to exclusive `:end` (default string
length) as exactly one JSON value, rejecting trailing data within that range.
→ [Reading JSON](../guide/reading.md#parse)

### `parse-prefix`

```lisp
(json-kit:parse-prefix string &rest options)   ; also accepts :index
  => value, end-index
```

Parse the first value at or after `:index` and return it plus the exclusive end
index. → [Reading JSON](../guide/reading.md#parse-prefix)

### `read-json`

```lisp
(json-kit:read-json stream &rest parse-options)
  => value
```

Read exactly one JSON value from a character stream, leaving the following
character unread. → [Reading JSON](../guide/reading.md#read-json)

### `read-json-line`

```lisp
(json-kit:read-json-line stream &rest parse-options)
  => value, present-p
```

Read one LF- or CRLF-terminated line and parse exactly one JSON value. Return
`nil, nil` at EOF before any characters. A final complete value without a
newline returns the value and `t`.
→ [Reading JSON](../guide/reading.md#read-json-line)

## Schema validation

```lisp
(json-kit:validate-schema value schema)
  => valid-p, failures
```

Validate a value using the default `parse` representation: string-keyed hash
tables, array vectors, strings, numbers, `t`, `+json-false+`, and `+json-null+`.
Schemas use the same representation. Alists, list arrays, and custom sentinel
mappings are outside the contract.

`failures` is a list of plists with `:path`, a JSON Pointer into the value, and
`:reason`, a string describing the mismatch. Successful validation returns
`t, nil`. The empty pointer denotes the root, and object keys escape `~` as
`~0` and `/` as `~1`.

| Keyword | Supported form |
| --- | --- |
| `type` | One type name or an array of names: `null`, `boolean`, `object`, `array`, `number`, `integer`, `string`. Mathematical integers such as `1.0` satisfy `integer`. |
| `required` | An array of property names that must exist on an object. |
| `properties` | An object mapping property names to schemas. |
| `enum` | An array of allowed JSON values, compared structurally. |
| `items` | One schema applied to every array element. |
| `additionalProperties` | True (default), false, or a schema for properties not named in `properties`. |
| `oneOf` | An array of schemas; exactly one must match. |

Boolean schemas (`t` and `+json-false+`) accept or reject every value.
The whole schema is checked before the value is validated. Unsupported
keywords, including `$schema`, `$id`, and `title`, and malformed schemas signal
`json-schema-error`. No keyword is silently ignored.

| Symbol | Kind | Meaning |
| --- | --- | --- |
| `json-schema-error` | condition | Invalid or unsupported schema; subtype of `json-kit-error`. |
| `json-schema-error-path` | reader | JSON Pointer into the schema. |
| `json-schema-error-message` | reader | Reason the schema cannot be used. |

## Writing

### `stringify`

```lisp
(json-kit:stringify value &key pretty indent max-depth max-output-length
                               max-elements sort-keys
                               null-value false-value number-encoder)
  => string
```

Serialize a value to a JSON string. → [Writing JSON](../guide/writing.md#stringify)

### `write-json`

```lisp
(json-kit:write-json value stream
                     &key pretty indent max-depth max-elements
                          max-output-length sort-keys
                          null-value false-value number-encoder)
  => value
```

Write a value to an existing character stream and return the original value.
→ [Writing JSON](../guide/writing.md#write-json)

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
implementation type. → [Data Model and Mapping](../guide/data-model.md#opaque-null-and-false)

## Base condition

| Symbol | Kind | Meaning |
| --- | --- | --- |
| `json-kit-error` | condition | Base of every condition this library signals (subtype of `error`). Carries no slots. |

→ [Error Handling](conditions.md#the-shared-base-condition)

## Parse diagnostics

| Symbol | Kind | Meaning |
| --- | --- | --- |
| `json-parse-error` | condition | Signalled for malformed input (subtype of `json-kit-error`). |
| `json-parse-error-position` | reader | Zero-based character offset. |
| `json-parse-error-line` | reader | One-based line. |
| `json-parse-error-column` | reader | One-based column. |
| `json-parse-error-path` | reader | Path of keys and indices to the failure. |
| `json-parse-error-expected` | reader | Short description of what was expected. |
| `json-parse-error-context` | reader | The `:context` label. |
| `json-parse-error-text` | function | Bounded, sanitized snippet of the input. |

→ [Error Handling](conditions.md#parse-errors)

## Serialization diagnostics

| Symbol | Kind | Meaning |
| --- | --- | --- |
| `json-serialization-error` | condition | Signalled for unsupported output (subtype of `json-kit-error`). |
| `json-serialization-error-message` | reader | Bounded failure description. |
| `json-serialization-error-path` | reader | Path to the offending value. |

→ [Error Handling](conditions.md#serialization-errors)

## Ordered-object bridges

| Symbol | Kind | Meaning |
| --- | --- | --- |
| `make-json-object` | function | Build an ordered object from `(key . value)` members. |
| `json-object-p` | function | Identify a `json-object`. |
| `json-object-members` | function | Return an ordered object's alist of members. |
| `alist->json-object` | function | Validate an alist and convert it to an object. |
| `json-object->alist` | function | Convert an object, hash table, or alist to an alist. |

→ [Conversion Helpers](../guide/conversion.md)

## Default option values

The defaults enforced by the entry points are:

| Option | Default | Applies to |
| --- | --- | --- |
| `start` | `0` | `parse` |
| `end` | `nil` (string length) | `parse` |
| `object-type` | `:hash-table` | reading |
| `array-type` | `:vector` | reading |
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

See [Resource Limits and Security](resource-limits.md) for the semantics of each
bound.
