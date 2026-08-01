# Getting Started

`cl-json-kit` has **no external Common Lisp runtime dependencies**. Only the
test system additionally uses [`cl-weave`](https://github.com/nerima-lisp/cl-weave).

## With Nix

The repository is a Nix flake. To build the ASDF system:

```sh
nix build github:nerima-lisp/cl-json-kit
```

The flake also exposes per-system attributes:

```sh
# Build the library for the current system.
nix build .#cl-json-kit

# Run the test suite as a reproducible derivation.
nix flake check

# Enter a devShell with SBCL and the competitor JSON libraries
# used by the benchmark harness.
nix develop

# Build this documentation site (Material for MkDocs, fully offline).
nix build .#docs
```

The `devShells.<system>.default` shell preloads Jzon, Jonathan, JSOWN, and
Yason so `benchmark/competitors.lisp` can compare against them. See
[Benchmarks](reference/benchmarks.md).

## With ASDF

Put the repository where ASDF can find it — for example under
`~/common-lisp/` or a directory on your `CL_SOURCE_REGISTRY` — then load it:

```lisp
(asdf:load-system "cl-json-kit")
```

Everything a caller needs is exported from the single `json-kit` package.
Every example on this site references symbols with the `json-kit:` prefix.

## Supported runtime

`cl-json-kit` targets **SBCL** first and is written in portable Common Lisp
elsewhere. The only implementation-specific behavior is the optional
`:timeout-seconds` wall-clock safeguard, which uses `sb-ext:with-timeout` on
SBCL and is a portable no-op on other implementations — the explicit size and
depth [limits](reference/resource-limits.md) remain the safeguards there.

## Verifying the install

A quick REPL round-trip confirms the system is loaded:

```lisp
(json-kit:stringify (json-kit:parse "[1,2,3]"))
;; => "[1,2,3]"
```

## Parse a document

Object keys are strings by default, and objects become hash tables:

```lisp
(defparameter *document*
  (json-kit:parse
   "{\"name\":\"Ada\",\"active\":false,\"note\":null,\"tags\":[\"a\",\"b\"]}"))

(gethash "name" *document*)             ; => "Ada", T
```

JSON `false` and `null` are represented by opaque sentinels, **not** by Lisp
`nil`. Test them with predicates rather than by identity or printed form:

```lisp
(json-kit:json-false-p (gethash "active" *document*)) ; => T
(json-kit:json-null-p  (gethash "note"   *document*)) ; => T
```

## Choose the container shape

The reader never guesses; you select the container types explicitly.

```lisp
(json-kit:parse "[1,2,3]" :array-type :list)
;; => (1 2 3)

(json-kit:parse "{\"name\":\"Ada\"}" :object-type :alist)
;; => (("name" . "Ada"))
```

## Unicode and surrogate pairs

`\uXXXX` escapes decode UTF-16 surrogate pairs into a single character, so
non-BMP code points such as emoji round-trip correctly:

```lisp
(json-kit:parse "\"\\ud83d\\ude00\"")
;; => "😀"
```

## Write to a string

Hash tables become objects; vectors and proper lists become arrays.

```lisp
(let ((table (make-hash-table :test #'equal)))
  (setf (gethash "name" table) "Ada"
        (gethash "missing" table) json-kit:+json-null+)
  (json-kit:stringify table :sort-keys t))
;; => "{\"missing\":null,\"name\":\"Ada\"}"
```

`:sort-keys t` makes member ordering deterministic — useful for tests and
diffs. Without it, hash-table iteration order is unspecified.

## Write to a stream

`write-json` writes characters to an existing stream, leaves it open, and
returns the original value:

```lisp
(with-open-file (out "result.json"
                     :direction :output
                     :if-exists :supersede
                     :element-type 'character)
  (json-kit:write-json #(1 2 3) out))
```

## Scan concatenated values

`parse-prefix` reads the first value and returns the exclusive end index, so
you can walk a stream of back-to-back values:

```lisp
(multiple-value-list (json-kit:parse-prefix "  [1,2] next"))
;; => (#(1 2) 7)
```

## Handle errors

Malformed input signals a typed condition that carries source coordinates and
a path into the document:

```lisp
(handler-case
    (json-kit:parse "{\"items\":[0,]}" :context "request body")
  (json-kit:json-parse-error (condition)
    (list :line   (json-kit:json-parse-error-line condition)
          :column (json-kit:json-parse-error-column condition)
          :path   (json-kit:json-parse-error-path condition)
          :expected (json-kit:json-parse-error-expected condition))))
```

See [Conditions](reference/conditions.md) for every reader on the condition
objects.

## Next steps

- [Data Model and Mapping](guide/data-model.md) — exactly how each JSON and
  Lisp value is represented.
- [Reading JSON](guide/reading.md) — every `parse` option, callbacks, and
  duplicate key policies.
- [Writing JSON](guide/writing.md) — pretty printing, sorting, and number
  encoding.
- [Resource Limits and Security](reference/resource-limits.md) — bounding
  untrusted input.
- [Troubleshooting](guide/troubleshooting.md) — thread safety, BOM handling,
  and other questions that come up past the basics.
