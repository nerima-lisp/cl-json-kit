# Changelog

All notable changes to this project will be documented in this file.

## [0.1.0] - Unreleased

### Added

- Initial rough draft of `cl-json-kit`: a dependency-free, SBCL-only JSON
  library exposing `parse` and `stringify`.
- `parse` supports `:object-type` (`:hash-table` / `:alist`), `:array-type`
  (`:vector` / `:list`), `:key-type` (`:keyword` / `:string`), a `:context`
  label for error messages, and an optional `:timeout-seconds` bound
  implemented via `sb-ext:with-timeout`.
- `\uXXXX` escapes decode UTF-16 surrogate pairs into a single character
  outside the Basic Multilingual Plane (e.g. emoji).
- Malformed input signals `json-parse-error` carrying `position`, `context`,
  and the original `text`.
- `stringify` dispatches purely by Lisp type (`hash-table` -> object,
  `vector`/`list` -> array) and never infers a cons list's intended JSON
  shape from its structure, structurally eliminating the object/array
  ambiguity bug found in earlier sibling JSON implementations.
- `alist->json-object` / `json-object->alist` bridge alists and the
  hash-table object representation explicitly.
