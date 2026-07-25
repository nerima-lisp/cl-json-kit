# Changelog

All notable changes to this project are documented here. This page mirrors
[`CHANGELOG.md`](https://github.com/nerima-lisp/cl-json-kit/blob/main/CHANGELOG.md)
at the repository root, which remains the source of truth. Releases are also
listed on the [GitHub releases page](https://github.com/nerima-lisp/cl-json-kit/releases).

## [Unreleased]

### Changed

- Internal readability pass over `src/`, all behavior-preserving: shared a
  single `emit-object-member` between hash-table and ordered-object
  serialization; reused `data.lisp`'s number-grammar vocabulary instead of
  re-deriving it as separate string literals in `json-number-string-p`;
  named `parse-object`'s two member-loop strategies and `parse-array`'s
  vector chunk-growth strategy as `labels` functions instead of leaving them
  inlined; extracted the coefficient-digit scan shared by
  `exact-number-range-value` and `decode-float-range`, and the control-char
  escape shared by `write-json-string`'s two branches.
- Removed `decode-integer-range`: unreachable since `scan-integer-fast`
  became a complete plain-integer scanner (bignums included), verified by a
  dynamic call trace across the full test suite (zero calls) plus a
  by-construction argument that every fallback case it existed for either
  signals in `scan-number` or turns out to be a float.
- Removed `do-mantissa-digits`: an orphaned macro with zero call sites,
  whose docstring referenced function names that no longer exist in `src/`.
- Consolidated the NIL/function/fbound-symbol callback-designator coercion
  that `resolve-parser-callback` (reader) and `resolve-number-encoder`
  (writer) each hand-wrote independently into one shared
  `resolve-callback-designator` macro.

## [0.3.0] - 2026-07-25

No public API or observable behavior changed in this release; it adds
documentation and CI/release infrastructure and continues the hot-path
performance work.

### Added

- Full MkDocs (Material) documentation site under `docs/` (this site),
  built offline via a new `docs` flake package and published to GitHub
  Pages on push to `main`.
- treefmt (nixfmt) formatting gate wired into `nix flake check`, a shared
  `nix-setup` composite GitHub Action, Dependabot coverage for GitHub
  Actions (including the nested composite action), and a scheduled
  `flake.lock` update workflow.

### Changed

- Further hot-path rework: number parsing derives sign/zero/scale directly
  from the source text range instead of allocating a token substring first;
  `\uXXXX` escape output writes hex nibbles directly instead of going
  through `format`; the writer's circular-reference guard hash table is now
  allocated lazily on first use instead of on every top-level write call;
  and whitespace classification uses a `case` over char-code.
- CI: concurrency guard to supersede in-flight runs, pinned `actions/checkout`
  with `persist-credentials: false`, and the flake now declares only
  `x86_64-linux` (the platform CI actually builds and tests).

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
