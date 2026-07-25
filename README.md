# cl-json-kit

[![CI](https://github.com/nerima-lisp/cl-json-kit/actions/workflows/ci.yml/badge.svg)](https://github.com/nerima-lisp/cl-json-kit/actions/workflows/ci.yml)
[![Publish documentation](https://github.com/nerima-lisp/cl-json-kit/actions/workflows/docs.yml/badge.svg)](https://github.com/nerima-lisp/cl-json-kit/actions/workflows/docs.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

`cl-json-kit` is a dependency-free JSON reader and writer for Common Lisp. It
provides string and character-stream APIs, explicit object/array mappings,
opaque values for JSON `null` and `false`, bounded resource use, and structured
diagnostics.

The core reader and writer use portable Common Lisp. On SBCL,
`:timeout-seconds` additionally uses `sb-ext:with-timeout`; other
implementations accept the option but parse without a wall-clock timeout.

📖 **Full documentation:** <https://nerima-lisp.github.io/cl-json-kit/> —
installation, a guided tour of reading/writing, the data model, error handling,
resource limits, an API reference, and the benchmark harness. The site is built
with MkDocs (Material) from `docs/`; build it locally with `nix build .#docs`.

## Why another JSON library?

The central rule is that JSON shape is never guessed from Lisp contents:

- A JSON object is a hash table or an alist, selected with `:object-type`.
- A JSON array is a vector or a list, selected with `:array-type`.
- When writing, hash tables are objects and vectors/lists are arrays.
- An alist becomes an object only after explicit conversion with
  `alist->json-object`.

This avoids silently treating an array of pairs as an object. The reader also
handles UTF-16 surrogate-pair escapes, rejects unpaired surrogates, reports an
error path and source location, and applies configurable bounds before
untrusted input can grow without limit.

## Installation

### Nix flake

```sh
nix build github:nerima-lisp/cl-json-kit
```

The flake also exposes `packages.<system>.cl-json-kit` and
`devShells.<system>.default`.

### ASDF

Put the repository where ASDF can find it, then load:

```lisp
(asdf:load-system "cl-json-kit")
```

The runtime system has no external Common Lisp dependencies. The test system
additionally uses `cl-weave`.

## Quick start

Object keys are strings by default:

```lisp
(defparameter *document*
  (json-kit:parse
   "{\"name\":\"Ada\",\"active\":false,\"note\":null,\"tags\":[\"a\",\"b\"]}"))

(gethash "name" *document*)             ; => "Ada", T
(json-kit:json-false-p
 (gethash "active" *document*))         ; => T
(json-kit:json-null-p
 (gethash "note" *document*))           ; => T

(json-kit:parse "[1,2,3]" :array-type :list)
;; => (1 2 3)

(json-kit:parse "{\"name\":\"Ada\"}" :object-type :alist)
;; => (("name" . "Ada"))

(json-kit:parse "\"\\ud83d\\ude00\"")
;; => "😀"
```

Write to a string or a character stream:

```lisp
(let ((table (make-hash-table :test #'equal)))
  (setf (gethash "name" table) "Ada"
        (gethash "missing" table) json-kit:+json-null+)
  (json-kit:stringify table :sort-keys t))
;; => "{\"missing\":null,\"name\":\"Ada\"}"

(with-open-file (out "result.json"
                     :direction :output
                     :if-exists :supersede
                     :element-type 'character)
  (json-kit:write-json #(1 2 3) out))
```

`+json-null+` and `+json-false+` are opaque sentinel values. Test them with
`json-null-p` and `json-false-p`; do not depend on their printed
representation or implementation type.

## Lisp/JSON mapping

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

`nil` is a proper empty list and is therefore written as `[]`, not as `null`
or `false`. A ratio is accepted only when its reduced denominator contains no
prime factors other than 2 and 5, so it has an exact finite decimal
representation. Other ratios, non-finite floats, dotted/circular lists,
circular aggregates, raw surrogate code points, non-string object keys, and
unsupported Lisp values signal `json-serialization-error`.

## Reading

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

(json-kit:parse-prefix string &rest options)

(json-kit:read-json stream &rest parse-options)
```

`parse` requires the entire string, apart from trailing JSON whitespace, to be
one JSON value. `parse-prefix` parses the first value at or after `:index` and
returns two values: the decoded value and the exclusive end index. Leading JSON
whitespace is accepted; whitespace and other data after the value remain
unconsumed:

Pass `:index` to start parsing at a later position; it defaults to zero.

```lisp
(multiple-value-list (json-kit:parse-prefix "  [1,2] next"))
;; => (#(1 2) 7)
```

`object-type` is `:hash-table` or `:alist`; `array-type` is `:vector` or
`:list`. Object keys are always strings; use `key-decoder` to transform a
decoded string key without interning attacker-controlled symbols:

```lisp
(json-kit:parse "{\"x-id\":17}"
                :key-decoder #'string-upcase)
```

`number-decoder`, when supplied, is called with the original JSON number token
and a boolean indicating whether the token has integer syntax:

```lisp
(json-kit:parse "1.25"
                :number-decoder
                (lambda (token integer-p)
                  (declare (ignore integer-p))
                  token))
;; => "1.25"
```

`object-hook` and `array-hook` receive each completed object or array,
respectively, and their return value replaces that aggregate in the result.
All four reader callbacks accept either a function object or a symbol naming a
globally bound function:

```lisp
(json-kit:parse "[1,2,3]" :array-type :list :array-hook 'reverse)
;; => (3 2 1)
```

Duplicate object keys are compared with `equal` after `key-decoder` transforms
them, then controlled by `duplicate-key-policy`:

- `:error` rejects a duplicate.
- `:first` keeps the first value.
- `:last` (default) keeps the last value.
- `:preserve` retains every pair, including duplicates, and requires
  `:object-type :alist`.

`read-json` consumes exactly one JSON value from the stream. It accepts leading
JSON whitespace and leaves the first character after the value unread, so it
can frame consecutive values by being called repeatedly. It does not decode
bytes or close the stream. For UTF-8 files or sockets, configure the Common
Lisp stream's external format yourself before calling it. There is no
octet/UTF-8 API.

## Writing

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
returns the original value. `stringify` is the string-returning wrapper; both
share the `max-output-length` character-count limit. Stream output is
incremental rather than transactional:
if serialization signals an error, an already-written prefix can remain in
the stream.

Hash-table iteration order is unspecified when `sort-keys` is false. When
true, object members are sorted lexicographically by their string keys for
deterministic output. Pretty printing adds newlines and `indent` spaces per
level.

`number-encoder` may override the formatting of supported numbers. It receives
a Lisp number and must return a string that matches the JSON number grammar;
it can provide representations for non-terminating ratios, but non-finite
floats remain unacceptable. The built-in writer preserves negative
floating-point zero and emits exact decimal text for terminating ratios, but
does not implement RFC 8785 canonical number formatting. Consequently,
`sort-keys t` gives deterministic member ordering, not RFC 8785 canonical JSON
or a cross-implementation byte-for-byte guarantee.

```lisp
(json-kit:stringify 1/8) ; => "0.125"
;; (json-kit:stringify 1/3) signals JSON-SERIALIZATION-ERROR
(json-kit:stringify 1/3 :number-encoder (constantly "0.333"))
;; => "0.333"
```

## Conversion helpers

```lisp
(json-kit:make-json-object members
  &key (max-elements 1000000))

(json-kit:json-object-p value)

(json-kit:json-object-members object)

(json-kit:alist->json-object alist
  &key (duplicate-key-policy :error) (max-elements 1000000))

(json-kit:json-object->alist object
  &key (max-elements 1000000))
```

`alist->json-object` validates a proper, acyclic alist with string keys and
accepts `:error`, `:first`, `:last`, or `:preserve` as its duplicate policy.
The first three policies return a hash table. `:preserve` returns a
`json-object` whose member order and duplicate keys are preserved.
`make-json-object` constructs the same explicit representation directly;
`json-object-p` identifies it and `json-object-members` returns its ordered
alist. `json-object->alist` accepts a `json-object`, hash table, or validated
alist. Hash-table conversion does not define pair order.

```lisp
(json-kit:stringify
 (json-kit:alist->json-object
  (list (cons "a" 1) (cons "b" 2)))
 :sort-keys t)
;; => "{\"a\":1,\"b\":2}"
```

A plain list remains a JSON array and is never inferred to be an object:

```lisp
(json-kit:stringify (list (cons 1 2) (cons 3 4)))
;; signals JSON-SERIALIZATION-ERROR because the nested conses are dotted lists
```

Duplicate object members can round-trip through the explicit representation:

```lisp
(let* ((text "{\"a\":1,\"a\":2}")
       (members (json-kit:parse text
                  :object-type :alist
                  :duplicate-key-policy :preserve))
       (object (json-kit:alist->json-object
                members
                :duplicate-key-policy :preserve)))
  (json-kit:stringify object))
;; => "{\"a\":1,\"a\":2}"
```

## Resource limits and security boundaries

Defaults are deliberately finite:

| Operation | Limit | Default | Unit/scope |
| --- | --- | ---: | --- |
| read | `max-input-length` | 16 Mi | characters in the complete input |
| read | `max-string-length` | 1 Mi | decoded characters in one string |
| read | `max-number-length` | 1024 | characters in one number token |
| read | `max-exact-exponent` | 10,000 | absolute decimal scale used by exact numeric fallback |
| read | `max-array-elements` | 1,000,000 | elements in one array |
| read | `max-object-members` | 1,000,000 | members in one object |
| read/write | `max-depth` | 512 | nested arrays/objects |
| write | `max-elements` | 1,000,000 | aggregate elements and members |
| write | output limit | 16 Mi | emitted characters |

Limits accept exactly the configured boundary and reject the next unit:

```lisp
(json-kit:parse "\"1234\"" :max-string-length 4) ; => "1234"
(json-kit:parse "\"12345\"" :max-string-length 4) ; signals JSON-PARSE-ERROR

(json-kit:parse "[1]" :max-array-elements 1)      ; => #(1)
(json-kit:parse "[1,2]" :max-array-elements 1)    ; signals JSON-PARSE-ERROR

(json-kit:stringify "abc" :max-output-length 5)  ; => "\"abc\""
(json-kit:stringify "abc" :max-output-length 4)  ; signals serialization error
```

Choose limits for the trust boundary instead of relying on the defaults for
every workload. On SBCL, `timeout-seconds` is an additional wall-clock
safeguard; it does not replace size/depth limits, and interruption timing is
subject to SBCL's timeout semantics. On other implementations the option is a
portable no-op, so the explicit size and depth limits remain the safeguards.

## Diagnostics

Malformed input signals `json-parse-error`. Public readers provide:

- `json-parse-error-position` (zero-based character offset)
- `json-parse-error-line` and `json-parse-error-column` (one-based)
- `json-parse-error-path` (object keys and array indices)
- `json-parse-error-expected`
- `json-parse-error-context`
- `json-parse-error-text` (a bounded, sanitized snippet)

Serialization failures signal `json-serialization-error`, with
`json-serialization-error-message` and `json-serialization-error-path`.
Diagnostic context, paths, and snippets are bounded to avoid echoing an
unbounded amount of untrusted data.

```lisp
(handler-case
    (json-kit:parse "{\"items\":[0,]}" :context "request body")
  (json-kit:json-parse-error (condition)
    (list :line (json-kit:json-parse-error-line condition)
          :column (json-kit:json-parse-error-column condition)
          :path (json-kit:json-parse-error-path condition)
          :expected (json-kit:json-parse-error-expected condition))))
```

## RFC 8259 scope

The reader accepts one complete RFC 8259 JSON text: objects, arrays, strings,
numbers, `true`, `false`, and `null`, with only JSON-defined whitespace.
String escapes include UTF-16 surrogate-pair combination for non-BMP
characters. Unescaped control characters, malformed escapes, lone surrogates,
invalid number forms and trailing data are rejected. The built-in decoder maps
ordinary non-integer numbers to double floats. When float conversion overflows
or underflows, it falls back to an exact integer or ratio instead of rejecting
an otherwise valid JSON number; for example, `1e400` remains an exact integer.
`max-exact-exponent` must be a non-negative integer and bounds the absolute
decimal scale used by that fallback, preventing an untrusted exponent from
requesting an enormous `expt` computation.
Supply `number-decoder` when the application needs its own decimal type or
uniform number representation.

The API operates on Common Lisp characters, not octets. Encoding validity and
UTF-8 decoding errors therefore belong to the stream/external-format layer.
The writer emits non-ASCII Lisp characters directly and escapes required JSON
characters; it does not promise ASCII-only output. RFC 8785 canonicalization,
multiple-value stream framing, comments, trailing commas, JSON5 extensions,
and arbitrary-precision decimal preservation without a custom
`number-decoder`/`number-encoder` are non-goals.

Conformance is measured rather than asserted. The whole parsing corpus of
[JSONTestSuite](https://github.com/nst/JSONTestSuite) is vendored into
`t/rfc8259-conformance-test.lisp` and runs on every build: all 95 `y_`
must-accept cases are accepted, all 188 `n_` must-reject cases are rejected,
nothing crashes or signals anything but `json-parse-error`, and this library's
answer to each implementation-defined `i_` case is pinned by a test so it cannot
change silently. See
[RFC 8259 Scope](https://nerima-lisp.github.io/cl-json-kit/rfc-8259/) for the
full breakdown.

## Compatibility

From 1.0.0 on, the exported surface of the `json-kit` package and its documented
behavior follow [Semantic Versioning](https://semver.org/). The export list and
the presence of a docstring on every exported symbol are asserted by the test
suite, so the public API cannot change by accident. Internal (`json-kit::`)
symbols, the exact text of error messages, and benchmark numbers are explicitly
not covered — see the
[Compatibility Promise](https://nerima-lisp.github.io/cl-json-kit/compatibility/)
for the full statement.

## Testing

```sh
sbcl --script run-tests.lisp
```

or:

```sh
nix flake check
```

## Benchmarks

The `benchmark/` directory holds two reproducible SBCL harnesses. `run.lisp`
measures the library's own string and stream reader/writer APIs; `competitors.lisp`
compares its string DOM APIs against Jzon, Jonathan, JSOWN, and Yason. Both emit
human-readable progress to standard error and machine-readable TSV, with full
provenance (host, SBCL, pinned sources, and execution order) embedded in the
output. The default `nix develop` shell provides the competitor libraries:

```sh
# The library's own reader/writer throughput:
sbcl --noinform --disable-debugger --script benchmark/run.lisp > results.tsv

# Comparison against the other libraries:
nix develop --command sbcl --noinform --disable-debugger \
  --script benchmark/competitors.lisp > competitor-results.tsv
```

These measurements are scoped to the recorded corpus, settings, SBCL version,
and host; see `benchmark/README.md` for the environment variables, the TSV
schema, and the correctness gates each harness runs before timing.

## License

MIT. See [LICENSE](LICENSE).
