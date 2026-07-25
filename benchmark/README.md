# cl-json-kit benchmarks

The benchmark directory contains two SBCL harnesses:

- `benchmark/run.lisp` measures cl-json-kit, including its string and stream
  writer APIs and its string and stream reader APIs.
- `benchmark/competitors.lisp` compares the string DOM APIs of cl-json-kit,
  Jzon, Jonathan, JSOWN, and Yason.

Run either script from the repository root. Progress and human-readable
summaries go to standard error; machine-readable TSV goes to standard output.

## Environment

Both harnesses accept these environment variables:

| Variable | Default | Allowed values | Meaning |
| --- | --- | --- | --- |
| `BENCH_OPERATIONS` | `all` | `all`, `parse`, `stringify` | Select the measured operation family. |
| `BENCH_SEED` | `20260724` | decimal integer at least 0 | Seed the per-round case shuffle. |
| `BENCH_WARMUP` | `2` | decimal integer at least 0 | Number of warmup rounds. |
| `BENCH_ITERATIONS` | `5` | decimal integer at least 1 | Number of independent measured samples per case. |

`benchmark/run.lisp` also accepts `CL_JSON_KIT_ROOT`. It loads
`cl-json-kit.asd` from that directory; without the variable, it loads the
checkout containing the script.

`BENCH_OPERATIONS=parse` is parse-only execution. The standalone harness does
not create writer cases or writer streams. The competitor harness does not run
stringify correctness gates, create stringify cases, or invoke adapter
stringify functions. `BENCH_OPERATIONS=stringify` selects the standalone
string and stream writers and the competitor native stringify cases.

The minimal parse-only competitor command is:

```sh
BENCH_OPERATIONS=parse nix develop --command sbcl --noinform \
  --disable-debugger --script benchmark/competitors.lisp \
  > competitor-parse.tsv
```

## cl-json-kit harness

Run the standalone harness with:

```sh
sbcl --noinform --disable-debugger --script benchmark/run.lisp \
  > benchmark-results.tsv
```

For example, select parse cases and change the seed and sample counts with:

```sh
BENCH_OPERATIONS=parse BENCH_SEED=7 BENCH_WARMUP=3 BENCH_ITERATIONS=10 \
  sbcl --noinform --disable-debugger --script benchmark/run.lisp \
  > benchmark-results.tsv
```

The harness measures three approximately 1 MiB strings with different escape
densities, integer and floating-point JSON arrays, an integer-valued JSON
object, and the public `json-kit:read-json` stream API. The float array is
exactly 1 MiB. `reader/read-json-array` creates a fresh string input stream
inside every measured call, so its result includes stream-creation cost.

Writer throughput uses the original Lisp string length as `input_bytes`, not
the escaped JSON output length. `writer/stringify/*` creates a result string.
`writer/stream/*` writes to `/dev/null` and forces the stream after each call.
Reader throughput uses the JSON input string length.

Before measurement, every selected case must pass its validator. Reader
validators check the root type, exact element or member count, and every
expected value. Object validation also checks the presence and value of every
key. Writer validators reparse the produced JSON and compare the complete
source string.

The standalone TSV contains three record families. Metadata uses the header
`record`, `key`, `value` and these exact keys:

- schema: `schema`, `schema_version`;
- run time: `run_utc`;
- source identity: `source_root`, `git_head`, `git_tree`, `git_dirty`;
- pinned dependency identity: `nixpkgs_lock`;
- host: `hostname`, `cpu`, `machine`, `os`, `os_version`;
- Lisp: `lisp_implementation`, `lisp_version`;
- settings: `seed`, `operations`, `warmup_rounds`, `sample_rounds`, `timer`,
  `allocation_counter`; and
- source hashes: `hash_benchmark_run`, `hash_benchmark_competitors`,
  `hash_benchmark_readme`, `hash_flake_nix`, `hash_flake_lock`.

Order rows use:

```text
record  phase  round  round_seed  case_count  case_ids
```

Result rows use:

```text
record  name  category  operation  workload  samples  input_bytes
wall_seconds_median  wall_seconds_min  wall_seconds_max
throughput_mib_s_median  throughput_mib_s_min  throughput_mib_s_max
consed_bytes_median  consed_bytes_min  consed_bytes_max
```

The displayed spaces represent TSV fields, not a space-delimited format.

## Competitor harness

The Nix flake pins nixpkgs and the packaged competitor sources. Run the
comparison inside that environment:

```sh
nix develop --command sbcl --noinform --disable-debugger \
  --script benchmark/competitors.lisp > competitor-results.tsv
```

For a smoke test:

```sh
BENCH_WARMUP=0 BENCH_ITERATIONS=1 \
  nix develop --command sbcl --noinform --disable-debugger \
  --script benchmark/competitors.lisp > competitor-smoke.tsv
```

The native stringify workloads are 1 MiB Lisp strings containing no escapes,
1% quotes, and 20% quotes. Parse workloads are an integer array, an
integer-valued object, and an escaped string. Stream APIs are excluded because
the libraries do not expose equivalent public stream interfaces. Use
`benchmark/run.lisp` for cl-json-kit's separate stream measurements.

### Correctness gates

All selected adapters pass correctness gates before any timing:

- array gates check the native or canonical root type, exact count, every
  indexed element, and the complete checksum;
- object gates check the root type, exact member count, presence of every key,
  and every associated value;
- string gates compare the complete decoded string; and
- identity gates parse one object containing JSON `null`, `false`, `true`,
  `[]`, and `{}`, check the root and empty-container types and counts, and
  require all five results to be distinct by identity.

Canonical identity gates additionally require `:null`, `:false`, `t`, an empty
vector, and an empty hash table.

Stringify gates are narrower: each result is reparsed with cl-json-kit and the
decoded string is compared with the source payload. Thus cl-json-kit is the
stringify oracle, not an independent JSON conformance implementation. A shared
interpretation or shared defect could pass this check, and these fixtures do
not constitute a complete JSON conformance suite.

### Native and canonical modes

`native` rows preserve each adapter's configured DOM and API:

- cl-json-kit and Jzon use hash-table objects and vector arrays;
- Jonathan uses hash-table objects and list arrays, with configured distinct
  scalar and empty-container sentinels;
- JSOWN uses `(:obj ...)` objects and list arrays, with configured distinct
  scalar and empty-array sentinels; and
- Yason uses hash-table objects and vector arrays with its boolean and null
  parsing options enabled.

These native rows intentionally retain representation and configuration
asymmetry. They compare the libraries' configured native work, not identical
DOM construction semantics. Native rows support claims only about these
configured end-to-end operations.

`canonical` parse rows normalize every result to hash-table objects with string
keys, vector arrays, `:null`, `:false`, and `t`. Parser options, dynamic
bindings, and recursive normalization are inside the measured operation.
Canonical rows therefore compare a common result contract but include
library-specific normalization cost. They are not parser-core measurements.
There are no canonical stringify rows.

### Ordering and samples

Each warmup and sample round applies a seeded, full Fisher–Yates permutation to
all selected cases. This avoids a fixed library or workload position while
remaining reproducible. The top-level `seed` metadata value and every round's
pre-shuffle `round_seed` are recorded together with the actual ordered
`case_ids` in `order` rows. Competitor case IDs have the form
`library|mode|operation|workload`.

Each sample performs one measured operation after a full SBCL GC outside the
timed interval. Results report median, minimum, maximum, and population standard
deviation for elapsed time, throughput, and bytes consed. Allocation data comes
from `sb-ext:get-bytes-consed`.

Raw sample rows are emitted in actual round and permutation order, before the
aggregate result rows. `order_index` is zero-based, and `elapsed_ticks` is
converted to `wall_seconds` using the recorded `timer_units_per_second`:

```text
record  phase  round  round_seed  order_index  case_id  library  version
dom  api  mode  operation  workload  input_bytes  elapsed_ticks
wall_seconds  throughput_mib_s  consed_bytes
```

### Self-contained TSV provenance

The competitor TSV starts with `meta` rows under the header `record`, `key`,
`value`. Its `schema_version` is `3`. The exact metadata keys are:

- schema: `schema`, `schema_version`;
- run time: `run_utc`;
- source identity: `source_root`, `git_head`, `git_tree`, `git_dirty`;
- pinned dependency identity: `nixpkgs_lock`;
- host: `hostname`, `cpu_model`, `machine_type`, `os`, `os_version`;
- Lisp: `lisp_implementation`, `lisp_version`;
- settings: `seed`, `operations`, `warmup_rounds`, `sample_rounds`,
  `timer_units_per_second`, `allocation_counter`; and
- source hashes: `sha256:cl-json-kit.asd`, `sha256:src/package.lisp`,
  `sha256:src/data.lisp`, `sha256:src/reader-macros.lisp`,
  `sha256:src/writer-macros.lisp`, `sha256:src/conditions.lisp`,
  `sha256:src/parser-state.lisp`, `sha256:src/reader-strings.lisp`,
  `sha256:src/reader-numbers.lisp`, `sha256:src/reader-collections.lisp`,
  `sha256:src/reader.lisp`, `sha256:src/reader-stream.lisp`,
  `sha256:src/writer-state.lisp`, `sha256:src/writer-scalars.lisp`,
  `sha256:src/writer-collections.lisp`, `sha256:src/writer.lisp`,
  `sha256:src/conversion.lisp`, `sha256:benchmark/competitors.lisp`,
  `sha256:benchmark/run.lisp`, `sha256:benchmark/README.md`,
  `sha256:flake.nix`, and `sha256:flake.lock`.

When discovery succeeds, `nixpkgs_lock` identifies the locked nixpkgs node
from `flake.lock` and the source hash keys contain SHA-256 digests. A failed
discovery is recorded as `unknown`; in particular, a failed Git status command
is never reported as a clean working tree. Hashing both `cl-json-kit.asd` and
the production component files identifies the exact system definition and
source contents used by the checkout. Together with the host, SBCL, settings,
raw samples, and actual order records, these rows keep the provenance needed to
interpret a result in the TSV itself.

Order rows use:

```text
record  phase  round  round_seed  case_count  case_ids
```

Result rows use:

```text
record  library  version  dom  api  mode  operation  workload  samples
input_bytes  wall_seconds_median  wall_seconds_min  wall_seconds_max
wall_seconds_stddev  throughput_mib_s_median  throughput_mib_s_min
throughput_mib_s_max  throughput_mib_s_stddev  consed_bytes_median
consed_bytes_min  consed_bytes_max  consed_bytes_stddev
```

Stringify throughput uses the original Lisp input length; parse throughput uses
the JSON input length.

## Interpreting claims

These measurements support comparisons only for the recorded corpus, operation
and mode, pinned source state, SBCL version, settings, execution order, and
host. Canonical parse rows support common-result-contract comparisons, including
normalization overhead. Native rows support configured end-to-end comparisons
only. Neither establishes parser-core performance or that any implementation is
universally the "world's fastest" JSON library. Publish a claim only with the
TSV artifact and scope it to the exact workload and environment recorded there.
