# Contributing

Contributions are welcome. This page covers the development workflow, how to run
the tests and benchmarks, and the conventions the codebase follows.

## Development environment

The repository is a Nix flake. The simplest way to get a working toolchain is:

```sh
nix develop
```

This drops you into a shell with SBCL and the competitor JSON libraries
(Jzon, Jonathan, JSOWN, Yason) that the [benchmarks](benchmarks.md) compare
against. If you use [direnv](https://direnv.net/), `direnv allow` loads it
automatically.

If you prefer a local SBCL, ensure `cl-json-kit` (and, for the tests,
`cl-weave`) are visible to ASDF, then load the system:

```lisp
(asdf:load-system "cl-json-kit")
```

## Running the tests

From a checkout:

```sh
sbcl --script run-tests.lisp
```

Or reproducibly, as a Nix derivation (this is what CI runs):

```sh
nix flake check
```

The test system (`cl-json-kit/test`) uses `cl-weave` and lives under `t/`. It
includes a property-based fuzzing suite over `parse`.

## Running the benchmarks

See [Benchmarks](benchmarks.md) for the full harness documentation. In short:

```sh
# The library's own reader/writer throughput.
sbcl --noinform --disable-debugger --script benchmark/run.lisp > results.tsv

# Comparison against other libraries (needs the nix develop shell).
nix develop --command sbcl --noinform --disable-debugger \
  --script benchmark/competitors.lisp > competitor-results.tsv
```

## Source layout

The reader and writer are split into small, per-concern files, loaded serially
by [`cl-json-kit.asd`](https://github.com/nerima-lisp/cl-json-kit/blob/main/cl-json-kit.asd):

| Area | Files |
| --- | --- |
| Package and shared data | `src/package.lisp`, `src/data.lisp` |
| Shared control flow | `src/reader-macros.lisp`, `src/writer-macros.lisp` |
| Conditions | `src/conditions.lisp` |
| Reader | `src/parser-state.lisp`, `src/reader-strings.lisp`, `src/reader-numbers.lisp`, `src/reader-collections.lisp`, `src/reader.lisp`, `src/reader-stream.lisp` |
| Writer | `src/writer-state.lisp`, `src/writer-scalars.lisp`, `src/writer-collections.lisp`, `src/writer.lisp` |
| Conversion | `src/conversion.lisp` |

The single public package `json-kit` is defined in `src/package.lisp`; only the
symbols listed there are part of the supported API. See the
[API Reference](api-reference.md).

## Conventions

- **Explicit shape, always.** The library never infers JSON object/array shape
  from the structure of a Lisp value. Any new feature must preserve this
  invariant — see [Data Model and Mapping](data-model.md).
- **Bound untrusted input.** New reader or writer paths that can grow with input
  size must be governed by a limit. See
  [Resource Limits and Security](security.md).
- **Bounded diagnostics.** Attacker-influenced strings, paths, and expected
  values in conditions are truncated and escaped at construction. Keep it that
  way.
- **Portable core, SBCL extras isolated.** The only implementation-specific
  behavior is the `:timeout-seconds` safeguard; everything else is portable
  Common Lisp.

## Building the documentation

The documentation is [Material for MkDocs](https://squidfunk.github.io/mkdocs-material/).
Build it reproducibly and fully offline with Nix:

```sh
nix build .#docs
# Rendered site is in ./result
```

Or, with a local MkDocs install:

```sh
mkdocs serve -f docs/mkdocs.yml     # live preview at http://127.0.0.1:8000
mkdocs build -f docs/mkdocs.yml --strict
```

`--strict` promotes broken links and pages missing from the navigation to build
failures, so keep the `nav:` in
[`docs/mkdocs.yml`](https://github.com/nerima-lisp/cl-json-kit/blob/main/docs/mkdocs.yml)
in sync with the files under `docs/src/`. Pushing a documentation change to
`main` publishes it to GitHub Pages via the
[`Publish documentation`](https://github.com/nerima-lisp/cl-json-kit/blob/main/.github/workflows/docs.yml)
workflow.

## Reporting issues

Use the [issue tracker](https://github.com/nerima-lisp/cl-json-kit/issues) for
bugs and questions. For a parse or serialization bug, include the exact input,
the options passed, the expected result, and what you observed — the
[error path and coordinates](error-handling.md) from the signalled condition
are especially helpful.
