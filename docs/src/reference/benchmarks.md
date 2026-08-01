# Benchmarks

The `benchmark/` directory holds two reproducible SBCL harnesses. Both emit
human-readable progress to standard error and machine-readable **TSV** to
standard output, with full provenance (host, SBCL version, pinned sources, and
execution order) embedded in the output itself.

!!! info "Full detail lives with the code"
    This page summarizes how to run the harnesses and read their output. The
    authoritative, exhaustive description — every environment variable, the
    complete TSV schema, and each correctness gate — is in
    [`benchmark/README.md`](https://github.com/nerima-lisp/cl-json-kit/blob/main/benchmark/README.md).

## The two harnesses

- **`benchmark/run.lisp`** measures cl-json-kit's own string and stream
  reader/writer APIs.
- **`benchmark/competitors.lisp`** compares its string DOM APIs against Jzon,
  Jonathan, JSOWN, and Yason.

## Running them

The library's own reader/writer throughput:

```sh
sbcl --noinform --disable-debugger --script benchmark/run.lisp > results.tsv
```

The comparison against other libraries — the competitor libraries are provided
by the default `nix develop` shell:

```sh
nix develop --command sbcl --noinform --disable-debugger \
  --script benchmark/competitors.lisp > competitor-results.tsv
```

A fast smoke test with no warmup and a single sample:

```sh
BENCH_WARMUP=0 BENCH_ITERATIONS=1 \
  nix develop --command sbcl --noinform --disable-debugger \
  --script benchmark/competitors.lisp > competitor-smoke.tsv
```

## Environment variables

Both harnesses accept these:

| Variable | Default | Allowed values | Meaning |
| --- | --- | --- | --- |
| `BENCH_OPERATIONS` | `all` | `all`, `parse`, `stringify` | Which operation family to measure. |
| `BENCH_SEED` | `20260724` | integer ≥ 0 | Seed for the per-round case shuffle. |
| `BENCH_WARMUP` | `2` | integer ≥ 0 | Number of warmup rounds. |
| `BENCH_ITERATIONS` | `5` | integer ≥ 1 | Measured samples per case. |

`benchmark/run.lisp` also accepts `CL_JSON_KIT_ROOT` to point at a specific
checkout; without it, the script loads the checkout that contains it.

## What is measured

`run.lisp` measures three ~1 MiB strings with different escape densities,
integer and floating-point JSON arrays, an integer-valued JSON object, and the
public `read-json` stream API. Reader throughput uses the JSON input length;
writer throughput uses the original Lisp string length (not the escaped output
length).

`competitors.lisp` compares in two modes:

- **`native`** rows keep each library's configured DOM and API, so they compare
  the libraries' configured native work — not identical DOM construction.
- **`canonical`** parse rows normalize every result to hash-table objects with
  string keys, vector arrays, and the shared scalar markers, so they compare a
  common result contract but include per-library normalization cost.

## Correctness gates come first

Before any timing, every selected case must pass a validator: reader validators
check the root type, exact element or member count, and every expected value;
writer validators reparse the produced JSON and compare the complete source
string.

!!! note "cl-json-kit is the stringify oracle"
    Stringify gates reparse each result with cl-json-kit and compare against the
    source payload. cl-json-kit is therefore the oracle, not an independent JSON
    conformance implementation — a shared interpretation or defect could pass.
    These fixtures are not a complete JSON conformance suite.

## Interpreting the numbers

These measurements support comparisons **only** for the recorded corpus,
operation and mode, pinned source state, SBCL version, settings, execution
order, and host. They do not establish that any implementation is universally
the "fastest" JSON library.

!!! warning "Publish a claim only with its artifact"
    If you cite a result, publish the TSV artifact alongside it and scope the
    claim to the exact workload and environment recorded there. The provenance
    rows exist precisely so a number can be interpreted later.
