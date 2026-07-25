# Changelog

All notable changes to this project are documented here. This page mirrors
[`CHANGELOG.md`](https://github.com/nerima-lisp/cl-json-kit/blob/main/CHANGELOG.md)
at the repository root, which remains the source of truth. Releases are also
listed on the [GitHub releases page](https://github.com/nerima-lisp/cl-json-kit/releases).

## [0.2.0] - 2026-07-24

No public API or observable behavior changed in this release; it is an
internal modernization and performance pass over the 0.1.0 surface.

### Added

- Reproducible SBCL benchmark harness under `benchmark/`: `run.lisp` measures
  the library's own string and stream reader/writer APIs, and
  `competitors.lisp` compares its string DOM APIs against Jzon, Jonathan,
  JSOWN, and Yason. Both emit machine-readable TSV with full provenance (host,
  SBCL, pinned sources, execution order). The default `nix develop` shell now
  provides the competitor libraries. See [Benchmarks](benchmarks.md).

### Changed

- Reworked the internals for 2026 Common Lisp idioms: the monolithic
  `reader.lisp`/`writer.lisp` are split into per-concern files, shared types
  and constants moved to `src/data.lisp`, and cross-cutting control flow was
  consolidated into `src/reader-macros.lisp` / `src/writer-macros.lisp`.
- Faster hot paths, all behavior-preserving: plain integers are parsed without
  allocating a token string (fixnum accumulation with a bignum fallback); the
  default hash-table/`:last` object path skips its duplicate-tracking table;
  array parsing reuses one error-path cons per array instead of one per
  element; `\uXXXX` escapes decode with direct fixnum arithmetic; and string
  serialization flushes contiguous unescaped runs with a single write.
- Bumped the `cl-weave` test dependency to v0.10.0 and adopted property-based
  fuzzing of `parse`.
- Hardened CI with a wall-clock `timeout` around the test run and a per-test
  timeout budget.

## [0.1.0] - 2026-07-24

### Added

- First release of `cl-json-kit`: a dependency-free, SBCL-first JSON reader
  and writer for strings and character streams.
- Reading: `parse` (whole string), `parse-prefix` (one value plus the
  exclusive end position, for scanning concatenated values), and `read-json`
  (exactly one value from a stream, without over-consuming the following
  input).
- Parser options cover shape (`:object-type` `:hash-table`/`:alist`,
  `:array-type` `:vector`/`:list`, `:key-type` `:keyword`/`:string`),
  duplicate-key policy, custom `null`/`false`/`true` values, and
  `:key-decoder` / `:number-decoder` / `:object-hook` / `:array-hook`
  callbacks.
- Resource bounds guard untrusted input: `:max-depth`, `:max-input-length`,
  `:max-string-length`, `:max-number-length`, `:max-array-elements`,
  `:max-object-members`, and an optional `:timeout-seconds` (via
  `sb-ext:with-timeout`).
- Distinct sentinel markers `+json-null+` and `+json-false+` (with
  `json-null-p` / `json-false-p` predicates) keep JSON `null` and `false`
  distinguishable from Lisp `nil` and from each other.
- `\uXXXX` escapes decode UTF-16 surrogate pairs into a single character
  outside the Basic Multilingual Plane (e.g. emoji).
- Malformed input signals `json-parse-error` carrying `position`, `line`,
  `column`, `path`, `expected`, `context`, and a bounded snapshot of the
  offending `text`.
- Writing: `stringify` (to a string) and `write-json` (to a stream) dispatch
  purely by Lisp type (`hash-table` -> object, `vector`/`list` -> array) and
  never infer a cons list's intended JSON shape from its structure,
  structurally eliminating the object/array ambiguity bug found in earlier
  sibling JSON implementations. Options include `:pretty`, `:indent`,
  `:sort-keys`, `:null-value` / `:false-value`, a `:number-encoder`, and
  output bounds (`:max-depth`, `:max-elements`, `:max-output-length`).
- Serialization failures signal `json-serialization-error` carrying a
  `message` and a `path`.
- Ordered object representation via `make-json-object` / `json-object-p` /
  `json-object-members`, preserving member order and duplicate keys, plus
  `alist->json-object` / `json-object->alist` to bridge alists explicitly.

!!! note "`:key-type` was removed after 0.1.0"
    0.1.0 accepted a `:key-type` option that only ever accepted its own
    default, `:string` — passing anything else signalled a parser-option
    error. Later modernization work dropped the vestigial option; since no
    caller could have passed a different value without erroring, this was not
    an observable behavior change, and no dedicated changelog entry covers the
    removal.
