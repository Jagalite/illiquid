# Source visibility row storage

This experiment compares the complete production `SourceBrowserFilter` at
`6f70cd2446fc6ef38d4e5a0fbf96f91b2234e635` with the working-tree implementation.
It measures live allocator growth immediately after one cold source-browser
projection returns, after its input fixture has been created. The input and
actor cache remain alive through sampling. Results do not describe whole-player
memory, resident memory, physical footprint, or peak allocation traffic.

## Reproduce

With Swift 6.1 or later on PATH, from the repository root:

```sh
python3 Benchmarks/SourceVisibilityStorage/run.py \
  --output /tmp/source-visibility-storage \
  --pairs 6 --sizes 1000,10000,100000
```

Use a new or empty output directory. The component package has no downloaded
dependencies. `--tests-only` runs the Swift correctness suites and baseline
negative control without building the benchmark, verifying workload bytes, or
measuring. It uses the historical filter with current support sources for both
variants; its receipt labels this adapted baseline as tests-only, not historical
performance qualification. `--skip-tests` skips tests for a separate measurement run.
For a quick exploratory check use `--pairs 2 --sizes 1000 --smoke`.

## Production-code boundary

The runner reuses the guarded source-extraction helper from
`Benchmarks/SourceTreeVisibility/run.py`. It compiles the complete filter and
tree-input files, actual core dependencies, and verbatim app value, matcher,
sorter, and row declarations. For performance measurement, historical baseline
and current candidate supporting source bytes must agree. Only
`SourceBrowserFilter.swift` may differ. No replacement row
types, actor, matcher, or projection implementation is measured.

Each receipt records the baseline commit, checkout HEAD, worktree state,
original and compiled source hashes, extracted-declaration hashes, harness and
binary hashes, compiler, host, command arguments, outputs, and exit statuses.
On Linux, the existing fixture's missing directory hint is made explicit and
Darwin/XML imports receive the same portability adaptations as the existing
source-tree benchmark. Native macOS sources receive no such adaptations.

## Workloads and sampling

| Case | Production entry point | Purpose |
| --- | --- | --- |
| `unchanged` | Prepared rows, default tree visibility | Normal unchanged projection |
| `nonmatching_rule` | Prepared rows, one enabled nonmatching regex | Rules evaluated, no rows changed |
| `hide_half` | Prepared rows, regex excludes alternate media | Filtered-output control |
| `hide_last` | Prepared rows, final row manually hidden | Late-prefix materialization control |
| `preview` | Prepared rows, alternate rows annotated and revealed | Annotation/control path |
| `tree_input` | Immutable tree input, one source listing | Real cached tree construction plus visibility |
| `hide_penultimate` | Prepared rows, next-to-last row hidden | Late prefix followed by an append |
| `preview_last` | Prepared rows, only final row annotated | Late annotation growth control |
| `keep_one` | Prepared rows, all except the final row hidden | Sparse-output allocation control |

Inputs use deterministic lexical URLs and synthetic file metadata. No media
files are decoded or scanned. The largest workload is a stress case, not a
claim about a typical user's library size.

Every measurement uses a fresh process, with six alternating AB/BA pairs per
case and size. Three independent eight-row projections warm the actor,
Foundation, matcher and observation paths before fixture construction. Fixture
creation is outside the samples. The driver samples live allocator bytes
before the cold filter/projection call and with the input, actor and result
explicitly retained afterward. It also records wall and process CPU time for
that single awaited call. Output snapshots, checksums and JSON encoding occur
only after sampling.

The allocator probes are `malloc_zone_statistics(NULL).size_in_use` on macOS
and `mallinfo2().uordblks + mallinfo2().hblkhd` on glibc Linux. These are
process-wide allocator counters: runtime/background allocations can contribute
noise. There is no forced autorelease-pool drain or quiescence interval, so the
sample can include autorelease-pending Foundation allocations. The output field
`retained_allocator_delta_bytes` means this at-return live allocation delta;
it is not a measurement of steady-state or post-drain retained heap. Common
input storage is already included before sampling and
is not counted again for every value alias. A nested pair of live array borrows
independently verifies storage sharing in the unchanged prepared-row cases.

The `tree_input` case includes row building, sorting and source cache retention.
Its total retained delta is therefore broader than the prepared-row cases.
The path set and thumbnail candidates are still constructed in all variants.

## Correctness gates

- Existing filter, tree-cache, search and media-organization tests plus the new
  storage suite run against baseline release and candidate debug/release builds
  with compiler warnings treated as errors.
- Only the new positive storage-sharing test is excluded from baseline semantic
  tests. It is then run alone and must fail, demonstrating the old duplicate
  row-array retention.
- Thirty-six independent verification workloads (nine cases at zero, one, 31
  and 257 rows) compare complete, length-delimited output bytes. The encoding
  includes every row field, annotation, recognized metadata field, hidden/rule
  counts, thumbnail URL and sorted media path. Raw outputs are retained as
  deterministic gzip files.
- All measured pairs must agree on output counts and the complete-output
  checksum. The source and executable hashes are checked again at completion.
- The focused macOS workflow separately builds the app dependency graph and
  tests the adjacent source-browser, empty-folder, search and organization
  suites with the pinned native SDK.

## Interpretation

The candidate shares the existing tree row array until a row is excluded or an
old/new visibility annotation requires the original assignment behavior. Swift
array copy-on-write keeps caller mutations and previously published snapshots
independent. The change retains the same row values and filtering semantics;
it avoids a second backing allocation when visibility leaves the input intact.

Once filtering changes a row, the accepted prefix is copied into a new array.
The candidate deliberately does not reserve capacity for the entire input, so
sparse filtered results do not acquire a full-sized output buffer. Controls
may still have similar allocation and CPU costs to the baseline. All paired
observations, including unfavorable ones, belong in the report.

When that prefix is nearly full, the next geometric growth request is capped
at the input count. This avoids requesting almost twice the needed capacity
after a late exclusion or annotation. Swift may round actual capacity above
the request; the driver records actual capacities separately from allocator
bytes. The `hide_penultimate`, `preview_last`, and `keep_one` controls qualify
both late growth and sparse results.

See [the research report](../../Documentation/SOURCE_VISIBILITY_STORAGE_MEMORY.md)
for qualified results and validation receipts.
