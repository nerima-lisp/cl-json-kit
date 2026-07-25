# FAQ

Answers to questions that come up once you go past the basic examples. For the
option-by-option reference, see [Reading JSON](reading.md) and
[Writing JSON](writing.md).

## Is `cl-json-kit` thread-safe?

Yes, for the common case of independent calls over independent data. The
reader never touches global mutable state: every `parse` / `parse-prefix` /
`read-json` call works through a freshly allocated parser-state struct that
only that call sees. The writer uses dynamic (`defvar`) special variables for
its configuration, but `write-json` and `stringify` establish fresh bindings
for all of them with `let` at the start of every call, so concurrent calls on
different threads never observe each other's bindings.

Two calls in different threads that each parse their own string and stringify
their own value need no external locking. What you must still manage
yourself:

- **A stream shared across threads.** `write-json` writes to whatever stream
  you pass it; a single stream written to concurrently by multiple threads
  needs its own synchronization, the same as with any other library.
- **A hash table or `json-object` shared across threads.** If two threads
  mutate or serialize the *same* mutable Lisp value concurrently, ordinary
  Common Lisp concurrency rules apply — `cl-json-kit` does not add any locking
  of its own around your data structures.

## Does the reader accept a UTF-8 byte-order mark (BOM)?

No. A leading `U+FEFF` is not JSON-defined whitespace, so it is rejected the
same as any other unexpected character:

```lisp
(json-kit:parse (format nil "~C{\"a\":1}" (code-char #xFEFF)))
;; signals JSON-PARSE-ERROR: expected JSON value, at line 1, column 1
```

Files saved by some editors and spreadsheet tools include a UTF-8 BOM. Strip
it before calling `parse` or `read-json` — see
[Strip a UTF-8 BOM before parsing](recipes.md#strip-a-utf-8-bom-before-parsing).

## Can I parse a huge file without materializing the whole value in memory?

Not as a streaming/SAX-style API. `cl-json-kit` is a DOM library: every
`parse`, `parse-prefix`, and `read-json` call builds the complete Lisp value
for one JSON value before returning it. `read-json`'s ability to frame
consecutive values on a stream (see [Reading JSON](reading.md#read-json)) lets
you process a large newline-delimited file one value at a time without holding
every value at once, but each individual value is still fully materialized.
Use [`max-depth`, `max-array-elements`, `max-object-members`, and
`max-input-length`](security.md) to bound how large any single value can
grow.

## How does this compare to Jzon, Jonathan, JSOWN, or Yason?

[Benchmarks](benchmarks.md) covers throughput, measured with the same
correctness-gated harness against all four. The API-level difference that
motivates this library, independent of speed, is explicit shape control: JSON
object/array shape is always chosen by you (`:object-type` / `:array-type`),
never inferred from whether a Lisp list of conses happens to look like an
alist. See [Why another JSON library?](README.md#why-another-json-library)
and [Data Model and Mapping](data-model.md) for the full rationale. This page
does not attempt a feature-by-feature matrix against the other libraries —
consult their own documentation for what they support.

## Will `(use-package :json-kit)` clash with `common-lisp` or another JSON library?

None of `json-kit`'s exported symbols (`parse`, `stringify`, `write-json`,
etc. — see the [API Reference](api-reference.md)) shadow a standard
`common-lisp` symbol, so `(use-package :json-kit)` is safe to add to a fresh
package. If you also use-package another JSON library in the same package,
check for a clash between the two libraries' own exports — `parse` and
`stringify` are common enough names that other libraries may export them too.
When in doubt, skip `use-package` and reference symbols with the `json-kit:`
prefix, as every example on this site does.

## Why doesn't my parsed float print exactly like the JSON literal I wrote?

Non-integer numbers decode to `double-float` by default, and not every
decimal literal has an exact binary `double-float` representation — the same
reason `0.1` doesn't print back exactly in JavaScript or Python either. See
[Numbers](data-model.md#numbers) for the overflow/underflow fallback to exact
rationals, and supply a
[`:number-decoder`](reading.md#number-decoder) if your application needs to
preserve the original decimal token or use its own decimal type.
