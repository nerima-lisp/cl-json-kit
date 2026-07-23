# Changelog

All notable changes to this project will be documented in this file.

## [0.1.0] - 2026-07-24

### Added

- First release of `cl-json-kit`: a dependency-free, SBCL-only JSON reader
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
