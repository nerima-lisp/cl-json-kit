# Development

The build, test, benchmark, and documentation commands for working on
`cl-json-kit` itself, plus the conventions the codebase follows.

For how to file an issue or open a pull request, see the org-wide
[CONTRIBUTING.md](https://github.com/nerima-lisp/.github/blob/main/CONTRIBUTING.md).

## Development environment

The repository is a Nix flake. Enter its development shell with:

```sh
nix develop
```

This drops you into a shell with SBCL and the competitor JSON libraries
(Jzon, Jonathan, JSOWN, Yason) that the [benchmarks](../reference/benchmarks.md)
compare against. If you use [direnv](https://direnv.net/), `direnv allow` loads
it automatically.

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

Two files there enforce project-wide contracts:

- **`t/public-api-test.lisp`** pins the exact set of symbols the `json-kit`
  package exports and requires a docstring on each. Adding or removing an export
  fails this spec by design — update the list in the same commit, and classify
  the change against the
  [Compatibility Promise](../reference/compatibility.md).
- **`t/rfc8259-conformance-test.lisp`** vendors the parsing corpus of
  [JSONTestSuite](https://github.com/nst/JSONTestSuite) (MIT) as data. It is
  vendored rather than fetched so conformance is checked offline inside the Nix
  sandbox. Each case is stored as a list of ASCII string chunks and character
  codes, which keeps the file pure ASCII and makes every code point explicit
  instead of dependent on the external format used to load the source. The 25
  corpus cases whose input is not well-formed UTF-8 are listed by name in the
  file's header and deliberately excluded, because this library's API consumes
  characters rather than octets.

## Running the benchmarks

See [Benchmarks](../reference/benchmarks.md) for harness details. The commands are:

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
| Writer | `src/writer-state.lisp`, `src/writer-numbers.lisp`, `src/writer-strings.lisp`, `src/writer-collections.lisp`, `src/writer.lisp` |
| Conversion | `src/conversion.lisp` |

The single public package `json-kit` is defined in `src/package.lisp`; only the
symbols listed there are part of the supported API. See the
[API](../reference/api.md).

## Conventions

- **Explicit shape, always.** The library never infers JSON object/array shape
  from the structure of a Lisp value. Any new feature must preserve this
  invariant — see [Data Model and Mapping](../guide/data-model.md).
- **Bound untrusted input.** New reader or writer paths that can grow with input
  size must be governed by a limit. See
  [Resource Limits and Security](../reference/resource-limits.md).
- **Bounded diagnostics.** Attacker-influenced strings, paths, and expected
  values in conditions are truncated and escaped at construction. Keep it that
  way.
- **Portable core, SBCL extras isolated.** The only implementation-specific
  behavior is the `:timeout-seconds` safeguard; everything else is portable
  Common Lisp.
- **Zero runtime dependencies, by design.** The runtime system depends on
  nothing outside the Common Lisp standard; only the test system uses
  `cl-weave`. Before adding a dependency, confirm that it supports a portable
  string/stream JSON codec. Use dependencies directly; do not add an adapter
  solely to satisfy a convention.

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

## Reporting a parse or serialization bug

Use the [issue tracker](https://github.com/nerima-lisp/cl-json-kit/issues).
Include the exact input, the options passed, the expected result, and the
observed — the [error path and coordinates](../reference/conditions.md) from
the signalled condition are especially helpful.
