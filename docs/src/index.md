# cl-json-kit

`cl-json-kit` is a **dependency-free JSON reader and writer for Common Lisp**.
It provides string and character-stream APIs, explicit object/array mappings,
opaque values for JSON `null` and `false`, bounded resource use, and structured
diagnostics.

The core reader and writer use portable Common Lisp. On SBCL,
`:timeout-seconds` additionally uses `sb-ext:with-timeout`; other
implementations accept the option but parse without a wall-clock timeout.

Start with [Getting Started](getting-started.md), then move on to
[Reading JSON](guide/reading.md) and [Writing JSON](guide/writing.md) for the
full API surface.

<div class="grid cards" markdown>

-   :material-rocket-launch: **Get started**

    ---

    Install with Nix or ASDF and parse your first document in minutes.

    [:octicons-arrow-right-24: Getting Started](getting-started.md)

-   :material-book-open-variant: **Learn the API**

    ---

    Reading, writing, conversion helpers, error handling, and limits.

    [:octicons-arrow-right-24: Reading JSON](guide/reading.md)

-   :material-file-document-outline: **Reference**

    ---

    Every exported symbol, its options, and the RFC 8259 scope.

    [:octicons-arrow-right-24: API reference](reference/api.md)

-   :material-shield-check: **Stable API**

    ---

    What 1.0 promises, what it deliberately does not, and how to report a break.

    [:octicons-arrow-right-24: Compatibility promise](reference/compatibility.md)

-   :material-speedometer: **Benchmarks**

    ---

    Reproducible SBCL harnesses with full provenance in the output.

    [:octicons-arrow-right-24: Benchmarks](reference/benchmarks.md)

</div>

## Why another JSON library?

The central rule is that **JSON shape is never guessed from Lisp contents**:

- A JSON object is a hash table or an alist, selected with `:object-type`.
- A JSON array is a vector or a list, selected with `:array-type`.
- When writing, hash tables are objects and vectors/lists are arrays.
- An alist becomes an object only after explicit conversion with
  [`alist->json-object`](guide/conversion.md).

This avoids silently treating an array of pairs as an object — a class of
ambiguity bug that has affected sibling JSON libraries. The reader also handles
UTF-16 surrogate-pair escapes, rejects unpaired surrogates, reports an error
path and source location, and applies configurable bounds before untrusted
input can grow without limit.

## Key features

- **Explicit shape control.** You decide whether objects become hash tables or
  alists and whether arrays become vectors or lists — the library never infers
  intent from a cons list's structure.
- **Distinct `null` and `false`.** `+json-null+` and `+json-false+` are opaque
  sentinels, kept distinguishable from Lisp `nil` and from each other.
- **Correct Unicode.** `\uXXXX` escapes decode UTF-16 surrogate pairs into a
  single non-BMP character (for example, emoji); lone surrogates are rejected.
- **Bounded by default.** Every reader and writer entry point enforces finite
  [size and depth limits](reference/resource-limits.md) suited to untrusted input.
- **Structured diagnostics.** Failures signal typed conditions carrying
  [position, line, column, path, and a bounded snippet](reference/conditions.md).
- **No runtime dependencies.** The runtime system depends on nothing beyond the
  Common Lisp standard; only the test system uses `cl-weave`.
- **Measured conformance.** The full [JSONTestSuite](https://github.com/nst/JSONTestSuite)
  parsing corpus is vendored into the test suite and runs on every build — all
  95 must-accept cases accepted, all 188 must-reject cases rejected, and every
  implementation-defined answer pinned. See [RFC 8259 Scope](reference/rfc-8259.md).
- **A stable API.** From 1.0.0 on, the exported surface follows
  [Semantic Versioning](reference/compatibility.md), and the export list itself is
  asserted by the test suite so it cannot change by accident.

## At a glance

```lisp
(defparameter *document*
  (json-kit:parse
   "{\"name\":\"Ada\",\"active\":false,\"note\":null,\"tags\":[\"a\",\"b\"]}"))

(gethash "name" *document*)                          ; => "Ada", T
(json-kit:json-false-p (gethash "active" *document*)) ; => T
(json-kit:json-null-p  (gethash "note"   *document*)) ; => T

(json-kit:parse "[1,2,3]" :array-type :list)         ; => (1 2 3)
(json-kit:parse "\"\\ud83d\\ude00\"")                ; => "😀"

(let ((table (make-hash-table :test #'equal)))
  (setf (gethash "name" table) "Ada")
  (json-kit:stringify table))                        ; => "{\"name\":\"Ada\"}"
```

## Lisp ↔ JSON mapping

| JSON | Default reader result | Writer input |
| --- | --- | --- |
| object | hash table with string keys | hash table with string keys |
| array | vector | vector or proper list |
| string | string | string |
| integer | integer | integer |
| non-integer number | implementation float | finite float or exact-decimal ratio |
| `true` | `t` | `t` |
| `false` | `+json-false+` | `+json-false+` |
| `null` | `+json-null+` | `+json-null+` |

See [Data Model and Mapping](guide/data-model.md) for the full rules, including the
treatment of `nil`, ratios, and unsupported values.

## Nix workflow

The [flake.nix](https://github.com/nerima-lisp/cl-json-kit/blob/main/flake.nix)
at the repository root packages `cl-json-kit` as a Nix flake:

- `nix build` — builds the ASDF system.
- `nix flake check` — runs the test suite as a reproducible derivation.
- `nix develop` — a devShell with SBCL and the competitor JSON libraries used by
  the [benchmarks](reference/benchmarks.md).
- `nix build .#docs` — builds this documentation site with MkDocs (Material).

## Project

`cl-json-kit` is part of the [nerima-lisp](https://github.com/nerima-lisp) org
and follows its shared community health files rather than keeping copies of
them here:

- [Contributing](https://github.com/nerima-lisp/.github/blob/main/CONTRIBUTING.md)
- [Code of Conduct](https://github.com/nerima-lisp/.github/blob/main/CODE_OF_CONDUCT.md)
- [Security policy](https://github.com/nerima-lisp/.github/blob/main/SECURITY.md)
- [Support](https://github.com/nerima-lisp/.github/blob/main/SUPPORT.md)

The build, test, benchmark, and documentation commands for this repository —
and the conventions its code follows — are in
[Development](project/development.md).

## License

MIT. See [LICENSE](https://github.com/nerima-lisp/cl-json-kit/blob/main/LICENSE).
