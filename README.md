# cl-json-kit

[![CI](https://github.com/nerima-lisp/cl-json-kit/actions/workflows/ci.yml/badge.svg)](https://github.com/nerima-lisp/cl-json-kit/actions/workflows/ci.yml)
[![Publish documentation](https://github.com/nerima-lisp/cl-json-kit/actions/workflows/docs.yml/badge.svg)](https://github.com/nerima-lisp/cl-json-kit/actions/workflows/docs.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A dependency-free JSON reader and writer for Common Lisp, with string and
character-stream APIs, explicit object/array mappings, opaque values for JSON
`null` and `false`, bounded resource use, and structured diagnostics.

📖 **Documentation: <https://nerima-lisp.github.io/cl-json-kit/>**

## Install

```sh
nix build github:nerima-lisp/cl-json-kit
```

or put the repository where ASDF can find it:

```lisp
(asdf:load-system "cl-json-kit")
```

The library itself has no external dependencies; only the test system uses
`cl-weave`. SBCL is the supported implementation — see
[Installation](https://nerima-lisp.github.io/cl-json-kit/installation/).

## Use

```lisp
(defparameter *document*
  (json-kit:parse
   "{\"name\":\"Ada\",\"active\":false,\"note\":null,\"tags\":[\"a\",\"b\"]}"))

(gethash "name" *document*)                           ; => "Ada", T
(json-kit:json-false-p (gethash "active" *document*)) ; => T
(json-kit:json-null-p  (gethash "note"   *document*)) ; => T

(json-kit:parse "[1,2,3]" :array-type :list)          ; => (1 2 3)
(json-kit:parse "\"\\ud83d\\ude00\"")                 ; => "😀"

(let ((table (make-hash-table :test #'equal)))
  (setf (gethash "name" table) "Ada")
  (json-kit:stringify table))                         ; => "{\"name\":\"Ada\"}"
```

`+json-null+` and `+json-false+` are opaque sentinels — test them with
`json-null-p` and `json-false-p` rather than depending on their printed form.

`parse-prefix` returns one value plus its end index, for scanning concatenated
values; `read-json` reads exactly one value from a character stream without
over-consuming. See [Reading](https://nerima-lisp.github.io/cl-json-kit/reading/)
and [Writing](https://nerima-lisp.github.io/cl-json-kit/writing/) for every
option.

## Why another JSON library?

**JSON shape is never guessed from Lisp contents.** A JSON object is a hash
table or an alist, chosen with `:object-type`; a JSON array is a vector or a
list, chosen with `:array-type`. When writing, hash tables are objects and
vectors and lists are arrays — an alist becomes an object only after an explicit
`alist->json-object`. An array of pairs can therefore never be silently written
as an object.

| JSON | Default reader result | Writer input |
| --- | --- | --- |
| object | hash table with string keys | hash table with string keys |
| array | vector | vector or proper list |
| string | string | string |
| integer | integer | integer |
| non-integer number | double float | finite float, or a ratio with an exact finite decimal expansion |
| `true` | `t` | `t` |
| `false` | `+json-false+` | `+json-false+` |
| `null` | `+json-null+` | `+json-null+` |

Note that `nil` is the empty list and is written as `[]`, never as `null` or
`false`. Full rules, including ratios and rejected values, are in the
[Data Model](https://nerima-lisp.github.io/cl-json-kit/data-model/).

## What you also get

- **Measured RFC 8259 conformance.** The whole parsing corpus of
  [JSONTestSuite](https://github.com/nst/JSONTestSuite) is vendored into the
  test suite and runs on every build: 95/95 must-accept cases accepted, 188/188
  must-reject cases rejected, nothing crashing or signalling anything but
  `json-parse-error`, and every implementation-defined answer pinned by a test.
  ([details](https://nerima-lisp.github.io/cl-json-kit/rfc-8259/))
- **A stable API.** From 1.0.0 on, the exported surface and its documented
  behavior follow [Semantic Versioning](https://semver.org/), and the export
  list is asserted by the test suite so it cannot change by accident.
  ([what is and is not covered](https://nerima-lisp.github.io/cl-json-kit/compatibility/))
- **Bounded by default.** Every entry point enforces finite input, output,
  depth, and element limits, plus an optional wall-clock timeout on SBCL.
  ([limits](https://nerima-lisp.github.io/cl-json-kit/security/))
- **Structured diagnostics.** Failures signal typed conditions carrying
  position, line, column, path, and a bounded, sanitized snippet.
  ([error handling](https://nerima-lisp.github.io/cl-json-kit/error-handling/))
- **Correct Unicode.** `\uXXXX` escapes decode UTF-16 surrogate pairs into a
  single non-BMP character; lone surrogates are rejected in both directions.

## Develop

```sh
sbcl --script run-tests.lisp   # or: nix flake check
```

`nix flake check` also runs the formatting gate and builds the documentation.
Benchmark harnesses live in [`benchmark/`](benchmark/README.md), and
[Contributing](https://nerima-lisp.github.io/cl-json-kit/contributing/) covers
the source layout and conventions.

## License

MIT. See [LICENSE](LICENSE).
