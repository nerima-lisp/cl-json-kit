# Compatibility Promise

`cl-json-kit` follows [Semantic Versioning](https://semver.org/). Reaching
1.0.0 is a commitment, not a milestone: from this release on, the surface
described below will not change incompatibly without a major version bump.

## What is covered

Everything the `json-kit` package exports, and the documented behavior of each:

- **the package name `json-kit` itself**, with no nicknames, so `json-kit:parse`
  keeps resolving;
- **the exported symbols** — the reading entry points (`parse`, `parse-prefix`,
  `read-json`), the writing entry points (`stringify`, `write-json`), the
  sentinels and their predicates (`+json-null+`, `+json-false+`, `json-null-p`,
  `json-false-p`), the condition types and every slot reader, and the ordered
  object bridges (`make-json-object`, `json-object-p`, `json-object-members`,
  `alist->json-object`, `json-object->alist`);
- **the keyword option names and their default values** on every entry point;
- **the Lisp/JSON mapping** described in
  [Data Model and Mapping](data-model.md), including which Lisp type each JSON
  type parses to and which JSON type each Lisp type serializes to;
- **the condition type signalled for each class of failure**: malformed input
  and invalid option values signal `json-parse-error`, unserializable values and
  exceeded output bounds signal `json-serialization-error`;
- **the [RFC 8259 conformance](rfc-8259.md) results**, which are enforced by the
  vendored JSONTestSuite corpus in the test suite.

The export list and the presence of a docstring on every exported symbol are
themselves asserted by `t/public-api-test.lisp`, so a symbol cannot enter or
leave the public surface without a deliberate, reviewed change.

## What is not covered

- **Internal symbols.** Anything reached through `json-kit::` rather than
  `json-kit:` is an implementation detail and may change in any release. The
  package exports exactly what is supported.
- **The exact text of error messages.** The condition *type* and its *slots* are
  stable and are the supported way to react to a failure programmatically;
  the human-readable report is free to improve. Match on
  `json-parse-error-position`, `-path`, or `-expected`, never on message text.
- **The exact digits a float serializes to.** The guarantees are that the output
  is a valid JSON number, that it reads back as a value `=` to the original, and
  that it depends only on the value serialized — never on ambient state such as
  `*read-default-float-format*`. A future release may print the same value more
  compactly.
- **Performance and benchmark numbers.** [Benchmarks](benchmarks.md) describe
  the current implementation, not a contract.
- **Anything under `t/` or `benchmark/`,** and the `cl-weave` test dependency,
  which is not a dependency of the library itself. `cl-json-kit` proper has no
  runtime dependencies, and that is covered.

## Supported implementation

SBCL is the supported and CI-verified implementation, on the platform the flake
declares (`x86_64-linux`). The reader and writer are portable Common Lisp apart
from two SBCL-specific points, both isolated and both feature-conditionalized:
`:timeout-seconds` uses `sb-ext:with-timeout`, and non-finite float detection
uses `sb-ext:float-nan-p` / `float-infinity-p` with a portable fallback. Other
conforming implementations are expected to work but are not verified, and a
break on one is a bug report rather than a compatibility violation.

## Deprecation policy

Within the 1.x line:

- nothing exported is removed or renamed;
- no option is removed, and no existing option's default value changes;
- new options and new exported symbols may be added in a minor release — code
  that does not name them is unaffected;
- anything intended for eventual removal is first documented as deprecated here
  and in the
  [release notes](https://github.com/nerima-lisp/cl-json-kit/releases), and
  keeps working for the rest of 1.x.

## Reporting a break

If an upgrade within 1.x changes behavior your code depended on and that
behavior is described above as covered, that is a bug: please open an issue on
the [tracker](https://github.com/nerima-lisp/cl-json-kit/issues) with the input
and the two versions involved.
