# Changelog

All notable changes to this project are documented here. This page mirrors
[`CHANGELOG.md`](https://github.com/nerima-lisp/cl-json-kit/blob/main/CHANGELOG.md)
at the repository root, which remains the source of truth. Releases are also
listed on the [GitHub releases page](https://github.com/nerima-lisp/cl-json-kit/releases).

## [Unreleased]

## [1.0.0] - 2026-07-25

The first stable release. The public API does not change here; what changes is
that it is now a promise. From this release on the exported surface of the
`json-kit` package and its documented behavior follow
[Semantic Versioning](https://semver.org/), as stated in
[Compatibility Promise](compatibility.md) — and both halves of
that promise are enforced by the test suite rather than by intent: the export
list and its docstrings are asserted by `t/public-api-test.lisp`, and RFC 8259
conformance is measured against the vendored JSONTestSuite corpus on every
build.

One real defect was found and fixed on the way here (float serialization
depending on ambient state; see *Fixed* below). It is listed as a fix rather
than a breaking change because it lands in the release that first makes a
compatibility promise, not after one.

### Added

- RFC 8259 conformance is now measured and enforced rather than asserted in
  prose. The whole parsing corpus of
  [JSONTestSuite](https://github.com/nst/JSONTestSuite) (MIT) is vendored into
  `t/rfc8259-conformance-test.lisp` and runs on every build: all 95 `y_`
  must-accept cases are accepted, all 188 `n_` must-reject cases are rejected,
  nothing crashes or signals anything but `json-parse-error`, and this
  library's answer to each of the 35 implementation-defined `i_` cases is
  pinned so it cannot change silently. The corpus is vendored as data rather
  than fetched so the check runs offline inside the Nix sandbox, and each case
  is stored as ASCII string chunks plus character codes so the file stays pure
  ASCII and every code point is explicit. The 25 cases whose input is not
  well-formed UTF-8 are excluded by name: this library's API consumes
  characters, not octets, so they exercise the external-format layer rather
  than the reader.
- `t/public-api-test.lisp` pins the exact set of symbols the `json-kit` package
  exports, requires a docstring on every one of them, and asserts the package
  name and absence of nicknames, so the public surface cannot change by
  accident ahead of a release that promises it is stable.
- A `docs/src/compatibility.md` page stating the 1.0 compatibility promise:
  what semantic versioning covers (exported symbols and their documented
  behavior, option names and defaults, the Lisp/JSON mapping, the condition
  type signalled for each failure class, the measured RFC 8259 results), what
  it deliberately does not (internal `json-kit::` symbols, exact error message
  text, exact float digits, benchmark numbers), the supported implementation,
  and the deprecation policy for the 1.x line.
- `nix flake check` now builds the documentation as well. The docs build runs
  `mkdocs --strict`, so a broken link or a page missing from the nav fails a
  pull request instead of failing the publish workflow after a merge to main.

### Changed

- Every exported symbol now carries a docstring. `define-condition` and
  `defstruct` have nowhere to put one on the readers and predicates they
  generate, so `json-parse-error`'s and `json-serialization-error`'s slot
  readers, and `json-object-p`, get theirs explicitly; both condition classes
  and each of their slots gained `:documentation` as well. `documentation` now
  answers at the REPL for the whole public surface rather than for the parts
  that happen to be written as `defun`s.

### Fixed

- Float serialization depended on the calling image's
  `*read-default-float-format*` rather than on the value alone. Common Lisp's
  printer appends a type marker (`d`/`f`/`s`/`l`) whenever a float's format
  differs from that variable, and the writer rewrote the marker to `e`, so the
  same double serialized as `3.14e0` in a default image and as `3.14` in one
  whose default had been set to `double-float` — while a single-float came out
  the other way round. Both forms are valid JSON and read back identically, but
  which one you got was a property of ambient state, not of the value.
  `json-float-string` now binds `*read-default-float-format*` to the value's own
  format, so output is a function of the value: `3.14d0` always serializes as
  `3.14`, `1.0d308` always as `1.0e308`. The marker rewrite is kept as a
  fallback for implementations that print one regardless.
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

- Bumped the `cl-weave` test dependency from v0.10.0 to v1.0.0 (`flake.lock`
  refreshed accordingly); required by `with-soft-assertions` below, which
  v0.10.0 does not export.
- `flake.nix`'s Nix packages now derive their version from `cl-json-kit.asd`'s
  `:version` form at eval time instead of duplicating it as a separate
  hardcoded string in two places, matching the pattern already used by the
  sibling `nerima-lisp/cl-weave` flake. Reformatted `cl-json-kit/test`'s
  dense single-line `:perform` form across multiple lines.
- Split `reader-test.lisp` and `writer-test.lisp` into 13 per-feature test
  files along their existing `describe`-block boundaries.
- Test suite adopts previously-unused `cl-weave` features: a
  `gen-recursive`-built arbitrary-nested-JSON generator backs a new
  round-trip property test, and `with-soft-assertions` collects every
  failure in a multi-field diagnostic assertion instead of stopping at the
  first.
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
- Removed `read-string-escape`: an orphaned function with zero call sites,
  superseded by `parse-escaped-string-rest`'s own inline escape decoding.
- Closed further coverage gaps found by a follow-up `sb-cover` audit: EOF
  and invalid-hex-digit handling inside a `\uXXXX` escape, `MAX-STRING-LENGTH`
  enforcement on a plain run following an earlier escape, every dispatch arm
  of `write-json-string`'s buffered (unbounded-output) branch, and
  `read-json`'s truncated-literal/string/container, non-stream-argument, and
  unrecognised-leading-character paths. `src/` coverage: 92.5% expression
  (3302/3569), 91.85% branch (575/626).
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
