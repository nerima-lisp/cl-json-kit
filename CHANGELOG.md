# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Fixed

- `json-parse-error` and `json-serialization-error` relied on an
  `initialize-instance :after` method to bound and escape
  attacker-influenced slots (`:context`, `:expected`, `:path`, `:message`)
  exactly once, at construction. SBCL's `define-condition` classes are not
  `standard-object`s and never dispatch through CLOS's `initialize-instance`
  protocol, so that method silently never ran: a caller-supplied `:context`
  string (or an oversized object key embedded in a serialization message)
  reached the condition completely unbounded and unescaped. Every
  construction site now goes through explicit `bounded-json-parse-error` /
  `bounded-json-serialization-error` constructor functions instead.

### Changed

- Split `reader-test.lisp` and `writer-test.lisp` into 13 per-feature test
  files along their existing `describe`-block boundaries.
- Test suite adopts previously-unused `cl-weave` features: a
  `gen-recursive`-built arbitrary-nested-JSON generator backs a new
  round-trip property test, and `with-soft-assertions` collects every
  failure in a multi-field diagnostic assertion instead of stopping at the
  first.

## [0.3.0] - 2026-07-25

No public API or observable behavior changed in this release; it adds
documentation and CI/release infrastructure and continues the hot-path
performance work.

### Added

- Full MkDocs (Material) documentation site under `docs/`, built offline via
  a new `docs` flake package and published to GitHub Pages on push to
  `main`. Covers installation, a guided tour of reading/writing, the data
  model, error handling, resource limits, RFC 8259 conformance notes,
  recipes, an FAQ, and an API reference.
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
  provides the competitor libraries. See `benchmark/README.md`.

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
