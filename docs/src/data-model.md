# Data Model and Mapping

The defining principle of `cl-json-kit` is that **JSON shape is decided
explicitly, never inferred from the structure of a Lisp value**. This page
documents the full correspondence in both directions.

## Mapping table

| JSON | Default reader result | Writer input |
| --- | --- | --- |
| object | hash table with string keys | hash table with string keys |
| array | vector | vector or proper list |
| string | string | string |
| integer | integer | integer |
| non-integer number | implementation float | finite float or a ratio with an exact finite decimal representation |
| `true` | `t` | `t` |
| `false` | `+json-false+` | `+json-false+` |
| `null` | `+json-null+` | `+json-null+` |

The reader's container choices are configurable: `:object-type` selects
`:hash-table` (default) or `:alist`, and `:array-type` selects `:vector`
(default) or `:list`. See [Reading JSON](reading.md).

## Opaque `null` and `false`

JSON `null` and `false` are represented by two distinct **opaque sentinel
values**, `+json-null+` and `+json-false+`. They are deliberately *not* Lisp
`nil`, and they are distinct from each other.

```lisp
(json-kit:json-null-p  json-kit:+json-null+)   ; => T
(json-kit:json-false-p json-kit:+json-false+)  ; => T
(eq json-kit:+json-null+ json-kit:+json-false+) ; => NIL
```

!!! warning "Test with predicates, not printed form"
    Use `json-null-p` and `json-false-p` to test these values. Do **not**
    depend on their printed representation or implementation type — both are
    unspecified and may change.

You can override the values the reader produces (`:null-value`,
`:false-value`, `:true-value`) and the values the writer recognizes
(`:null-value`, `:false-value`). This lets you map JSON `null` to `:null`, to
`nil`, or to any marker your application already uses.

## Why `nil` is an empty array

Common Lisp conflates the empty list and boolean false: both are `nil`. Because
`cl-json-kit` dispatches the writer purely by type, it treats `nil` as a
**proper empty list**, and therefore writes it as `[]`:

```lisp
(json-kit:stringify nil)   ; => "[]"
```

`nil` is never written as `null` or `false`. If you need JSON `null` or
`false`, use the sentinels `+json-null+` and `+json-false+` (or your configured
`:null-value` / `:false-value`).

## Objects are never inferred from cons structure

A plain list — even a list of conses that *looks* like an alist — remains a
JSON array. The writer will not silently reinterpret it as an object:

```lisp
(json-kit:stringify (list (cons 1 2) (cons 3 4)))
;; signals JSON-SERIALIZATION-ERROR: the nested conses are dotted lists,
;; which are not valid JSON array elements.
```

To serialize an alist as a JSON object, convert it explicitly with
[`alist->json-object`](conversion.md). This is the structural safeguard that
eliminates the array-of-pairs-vs-object ambiguity found in some other JSON
libraries.

## Numbers

- **Integers** map to Lisp integers in both directions, with arbitrary
  precision.
- **Non-integer numbers** are decoded to `double-float` by the built-in
  decoder. When float conversion would overflow or underflow, the reader falls
  back to an exact integer or ratio rather than rejecting an otherwise valid
  number — for example, `1e400` remains an exact integer. The
  `:max-exact-exponent` limit bounds the scale of that fallback.
- On the writer side, a **ratio** is accepted only when its reduced denominator
  has no prime factors other than 2 and 5, so it has an exact finite decimal
  representation:

    ```lisp
    (json-kit:stringify 1/8)   ; => "0.125"
    (json-kit:stringify 1/3)   ; signals JSON-SERIALIZATION-ERROR
    ```

  Supply a [`:number-encoder`](writing.md#number-encoder) to format other
  ratios or to impose a uniform number representation. Supply a
  [`:number-decoder`](reading.md#number-decoder) when reading if the
  application needs its own decimal type.

Negative floating-point zero is preserved by the writer. RFC 8785 canonical
number formatting is **not** implemented; see
[RFC 8259 Scope](rfc-8259.md).

## Unsupported writer inputs

The following signal `json-serialization-error` when written:

- non-finite floats (infinities and NaNs);
- ratios without an exact finite decimal representation (absent a
  `:number-encoder`);
- dotted or circular lists, and circular aggregates;
- raw surrogate code points in strings;
- non-string object keys;
- any other unsupported Lisp value.

See [Error Handling](error-handling.md) for the condition's slots.

## Characters, not octets

The entire API operates on Common Lisp **characters**, not octets. Encoding
validity and UTF-8 decoding belong to the stream / external-format layer: for
UTF-8 files or sockets, configure the stream's external format yourself before
calling `read-json` or `write-json`. There is no octet/UTF-8 API. See
[RFC 8259 Scope](rfc-8259.md) for the full boundary.
