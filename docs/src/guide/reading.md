# Reading JSON

`cl-json-kit` offers three reader entry points:

- [`parse`](#parse) — the whole string must be one JSON value.
- [`parse-prefix`](#parse-prefix) — read the first value and report where it
  ended, for scanning concatenated values.
- [`read-json`](#read-json) — read exactly one value from a character stream.

All three share the same option set (apart from the extra `:index` accepted by
`parse-prefix`).

## `parse`

```lisp
(json-kit:parse string
  &key
    (object-type :hash-table)
    (array-type :vector)
    (duplicate-key-policy :last)
    (null-value json-kit:+json-null+)
    (false-value json-kit:+json-false+)
    (true-value t)
    key-decoder
    number-decoder
    object-hook
    array-hook
    (max-depth 512)
    (max-input-length 16777216)
    (max-string-length 1048576)
    (max-number-length 1024)
    (max-exact-exponent 10000)
    (max-array-elements 1000000)
    (max-object-members 1000000)
    (context "json")
    timeout-seconds)
```

`parse` requires the **entire** string, apart from trailing JSON whitespace, to
be one JSON value. Anything else after the value is an error.

### Container shape

- `object-type` is `:hash-table` (default) or `:alist`.
- `array-type` is `:vector` (default) or `:list`.

```lisp
(json-kit:parse "[1,2,3]" :array-type :list)          ; => (1 2 3)
(json-kit:parse "{\"name\":\"Ada\"}" :object-type :alist)
;; => (("name" . "Ada"))
```

Object keys are always strings.

### Sentinels and boolean values

`:null-value`, `:false-value`, and `:true-value` override what the reader
produces for `null`, `false`, and `true`. Defaults are `+json-null+`,
`+json-false+`, and `t` respectively.

```lisp
(json-kit:parse "null" :null-value :nil)  ; => :NIL
```

## Callbacks

All four reader callbacks accept either a function object or a symbol naming a
globally bound function.

### `key-decoder`

Transforms a decoded string key. Use it to normalize keys without interning
attacker-controlled symbols:

```lisp
(json-kit:parse "{\"x-id\":17}" :key-decoder #'string-upcase)
;; => a hash table mapping "X-ID" to 17
```

Duplicate detection (below) compares keys *after* `key-decoder` runs.

### `number-decoder`

Called with the original JSON number token and a boolean indicating whether the
token has integer syntax. Its return value replaces the number:

```lisp
(json-kit:parse "1.25"
                :number-decoder
                (lambda (token integer-p)
                  (declare (ignore integer-p))
                  token))
;; => "1.25"
```

Supply this when the application needs its own decimal type or a uniform number
representation.

### `object-hook` and `array-hook`

Each receives a completed object or array, respectively, and its return value
replaces that aggregate in the result:

```lisp
(json-kit:parse "[1,2,3]" :array-type :list :array-hook 'reverse)
;; => (3 2 1)
```

## Duplicate object keys

Duplicate keys are compared with `equal` after `key-decoder` transforms them,
then resolved by `duplicate-key-policy`:

| Policy | Behavior |
| --- | --- |
| `:error` | Reject a duplicate with `json-parse-error`. |
| `:first` | Keep the first value. |
| `:last` (default) | Keep the last value. |
| `:preserve` | Retain every pair, including duplicates. Requires `:object-type :alist`. |

```lisp
(json-kit:parse "{\"a\":1,\"a\":2}")                       ; => a table with a => 2
(json-kit:parse "{\"a\":1,\"a\":2}" :duplicate-key-policy :first) ; => a => 1
(json-kit:parse "{\"a\":1,\"a\":2}"
                :object-type :alist
                :duplicate-key-policy :preserve)
;; => (("a" . 1) ("a" . 2))
```

`:preserve` output can round-trip through the explicit ordered-object
representation; see [Conversion Helpers](conversion.md).

## `parse-prefix`

```lisp
(json-kit:parse-prefix string &rest options)   ; also accepts :index
```

`parse-prefix` parses the first value at or after `:index` (default `0`) and
returns **two values**: the decoded value and the exclusive end index. Leading
JSON whitespace is accepted; whitespace and any other data after the value
remain unconsumed. This makes it the tool for scanning back-to-back values:

```lisp
(multiple-value-list (json-kit:parse-prefix "  [1,2] next"))
;; => (#(1 2) 7)

(multiple-value-list (json-kit:parse-prefix "[1][2]" :index 3))
;; => (#(2) 6)
```

Every other keyword matches `parse`.

## `read-json`

```lisp
(json-kit:read-json stream &rest parse-options)
```

`read-json` consumes exactly one JSON value from a character stream. It:

- accepts leading JSON whitespace;
- leaves the first character *after* the value unread, so repeated calls can
  frame consecutive values;
- does **not** decode bytes or close the stream.

```lisp
(with-input-from-string (in "  {\"ok\":true}  ")
  (json-kit:read-json in))
;; => a hash table mapping "ok" to T
```

!!! note "Configure the external format yourself"
    `read-json` operates on characters. For UTF-8 files or sockets, set the
    stream's external format before calling it. There is no octet/UTF-8 API.
    See [RFC 8259 Scope](../reference/rfc-8259.md).

## Resource limits

Every limit keyword (`:max-depth`, `:max-input-length`, `:max-string-length`,
`:max-number-length`, `:max-exact-exponent`, `:max-array-elements`,
`:max-object-members`, and the SBCL-only `:timeout-seconds`) is documented in
detail on [Resource Limits and Security](../reference/resource-limits.md). The defaults are finite
and deliberately conservative; tune them to your trust boundary.

## The `context` label

`:context` (default `"json"`) is a short label that appears in parse-error
reports, letting you distinguish, say, a request body from a config file:

```lisp
(json-kit:parse "{" :context "request body")
;; signals JSON-PARSE-ERROR whose report begins with "request body parse error…"
```
