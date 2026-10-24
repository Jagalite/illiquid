# Source-browser row storage

## Problem and change

`SourceBrowserFilter` retains the source rows in its tree/key cache and retains
the visibility result in a second cache. Previously, `visibility(from:...)`
always appended every accepted row to a new array, even if all rows and all
visibility annotations were unchanged. Strings and other referenced values
already have their own sharing behavior; the redundant allocation investigated
here is the array of `SourceTreeDisplayRow` values itself.

The candidate keeps an optional output array. While every row remains included
and both its existing and computed visibility annotations are absent, it can
return the original array. At the first exclusion or annotation it copies the
preceding unchanged prefix, then appends accepted rows.
Array copy-on-write preserves independent values for previously published
projections and callers that subsequently mutate their own arrays.

Growth after a difference is geometric but capped at the input count. This
avoids doubling a nearly complete prefix after a late annotation change without
reserving the entire input for a heavily filtered result. This caps the requested
capacity; the allocator can still round the actual capacity upward.

Visibility evaluation, regex counts, hidden-item counts, inherited folder
annotations, ordering, search, media grouping and cancellation checks remain in
their existing paths. Existing nonnil annotations always take the assignment
path, including when they compare equal: Swift String equality can equate rule
IDs with different Unicode bytes, and the newly computed spelling must still
replace the old one. Stale annotations still clear.

## Qualification status

Native macOS qualification is pending. Results and source-bound evidence will be
recorded here before opening a review-ready PR.

## Reproduction

Use a checkout containing the pinned baseline commit
`6f70cd2446fc6ef38d4e5a0fbf96f91b2234e635` and Swift 6.3 or later:

```sh
# Baseline semantic tests, candidate debug/release tests, complete output parity,
# and six alternating AB/BA pairs for each default scenario and size.
python3 Benchmarks/SourceBrowserRowStorage/run.py \
  --output /tmp/illiquid-source-row-storage \
  --pairs 6 --sizes 1000 10000 100000 --prove-baseline-failure

# Correctness and complete semantic comparisons without the measurement cohort.
python3 Benchmarks/SourceBrowserRowStorage/run.py \
  --output /tmp/illiquid-source-row-tests --tests-only --prove-baseline-failure
```

Output directories must be new or empty. The dedicated
`source-browser-row-storage.yml` workflow runs the component experiment and a
separate native app/test build on the research branch. Pull requests run the
correctness gates and native integration tests.

## Method

The comparison uses the production `SourceBrowserFilter`, visibility matcher,
row types, and projection types. The baseline filter is read from the pinned Git
commit; the candidate is read from the working tree. All other production
dependencies, tests, C helpers, harness code, and package settings are identical
between variants. The runner rejects differences outside the filter's
`visibility` method and verifies source and binary hashes again after the run.

The small standalone package uses the existing `SourceTreeVisibility` snapshot
helper and guarded verbatim declarations from the app. Native macOS sources and
tests are unmodified. Linux adapts the Darwin import, adds FoundationXML, and
provides the existing legacy sidecar test's explicit directory-URL hint; those
adaptations are recorded and identical between variants. Native integration
separately compiles the application/test dependency graph with its pinned SDK.

Fixtures use synthetic local URLs with ASCII, accented, decomposed-Unicode,
CJK, and emoji names. They require no media decoding or filesystem scanning in
the measured calls. They cover unchanged tree/files/folders, enabled rules that
match nothing, first/middle/last exclusions and annotations, heavy/all filtering,
already-correct and stale annotations, search, media grouping, and cached calls.
Complete canonical JSON for all 17 cases at 257 rows is compared byte for byte.
It contains every stored row, recognition, visibility and projection field.
Every measured observation also fingerprints its complete output and must agree
with all other observations for that scenario and size.

The default measurement cohort uses 12 cases, three row counts, and six balanced
AB/BA pairs. Each member runs in a fresh process; the default is one projection
per process. Setup and diagnostic serialization are outside the timed calls.
Both variants use the same benchmark-only autorelease pools around native
fixture construction and the synchronous actor projection so Objective-C
temporaries drain before the allocation sample. Production code is unchanged by
these pools. The fixture, actor cache, and returned result remain alive while
sampling.

### Reading the metrics

| Field | Interpretation |
| --- | --- |
| `retained_projection_delta_bytes` | Additional allocator-accounted live bytes between a prepared fixture/actor and the returned projection. |
| `retained_fixture_delta_bytes` | Additional live bytes including fixture creation and the retained actor/result. |
| `shares_input_storage` | Input and output buffer addresses compared during simultaneous valid borrows, after the memory sample. |
| `input_row_capacity`, `output_row_capacity`, `row_stride_bytes` | Structural array-storage diagnostics, separate from process allocation statistics. |
| `loop_wall_nanoseconds`, `loop_cpu_nanoseconds` | Awaited projection-call time, including actor handoff and native pool drainage. |

For `cache_hit`, the cache is primed **before** the projection baseline. Its
projection delta measures incremental hit overhead; use its fixture delta when
examining retained cache storage. All scenarios invoke `project(rows:...)`;
source-tree construction and file discovery are excluded.

On macOS, the C helper reads
`malloc_zone_statistics(NULL).size_in_use`. Apple's
[public declaration](https://github.com/apple-oss-distributions/libmalloc/blob/c49dafa25f1efe8607701ae6014a663ad2ee437f/include/malloc/malloc.h)
defines `NULL` as summing all malloc zones. These are allocator-accounted live
bytes, including allocation rounding and process/runtime allocations. They are
not an exact object-size sum, peak memory, RSS, GPU memory, or whole-player
footprint. The Linux corroborating metric is
`mallinfo2().uordblks + mallinfo2().hblkhd`.

## Scope and limitations

The change removes redundant row storage only when the visibility result is
unchanged. Filtered or newly annotated results still need independent arrays;
search and media grouping can also construct separate displayed arrays. A large
synthetic library demonstrates scaling but does not establish typical library
size or workload frequency.

This experiment does not measure application RSS, physical footprint, video
decoder memory, frame pacing, energy, or full UI responsiveness. Test and
measurement source hashes identify the tested implementation; documentation-only
follow-up commits do not change it.

Early sandboxed Linux exploration encountered the already documented
libdispatch/PID-namespace mismatch. Those timing cohorts are excluded, including
successful observations. The runner records the PID namespace and refuses
measurements when it does not match `/proc/self`; native macOS results are the
primary qualification.
