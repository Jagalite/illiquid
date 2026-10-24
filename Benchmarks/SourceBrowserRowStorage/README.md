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

## Results and qualification

**The portable component experiment confirms a retained-memory reduction. This PR remains a draft pending native macOS qualification.**

The accepted measurement cohort contains **432 fresh-process observations / 216 paired comparisons**: 12 scenarios, 1,000 / 10,000 / 100,000 input rows, and six balanced AB/BA pairs per scenario and size. All observations are retained, with no retries or exclusions from this cohort. All measured output fingerprints agree within each scenario and size.

These are **Linux x86_64 / Swift 6.3.2 component measurements**, not macOS or whole-player measurements. The exact production and harness source is commit [`914b87e`](https://github.com/Jagalite/illiquid/commit/914b87e4a587676b6d9e97aab0d4b8d26f4fd244); the baseline filter is pinned to `6f70cd2`. The source and executable hashes were checked before and after measurement. Documentation/evidence follow-ups do not change that implementation. Commit `fe8cb73` only narrows the research workflow to this PR; its production and benchmark inputs are identical.

The native component experiment and full application/test graph qualification are scheduled in [GitHub Actions run 40104705034](https://github.com/Jagalite/illiquid/actions/runs/40104705034). At publication they have not supplied a native result. Keep the PR in draft until those checks complete and the native memory/timing tradeoff is reviewed.

### Retained memory

The table below reports median **additional allocator-accounted live memory during projection**, with the input fixture and actor already alive at the baseline. Values are MiB (1 MiB = 1,048,576 bytes). Savings and percentages are median paired differences/ratios, rather than ratios inferred from rounded display values.

| Synthetic media rows, tree view | Baseline MiB | Candidate MiB | Saved MiB | Paired reduction |
| ---: | ---: | ---: | ---: | ---: |
| 1,000 | 0.464 | 0.143 | 0.320 | 69.073% |
| 10,000 | 6.356 | 1.233 | 5.123 | 80.603% |
| 100,000 | 54.799 | 13.803 | 40.996 | 74.812% |

The full 100,000-row controls show where the allocation changes. The tree-view fixture consists of flat synthetic media rows; this experiment does not time source-tree construction or filesystem discovery.

| Scenario | Output rows | Baseline MiB | Candidate MiB | Saved MiB | Paired reduction |
| --- | ---: | ---: | ---: | ---: | ---: |
| `tree` | 100,000 | 54.799 | 13.803 | 40.996 | 74.812% |
| `files` | 100,000 | 54.799 | 13.803 | 40.996 | 74.812% |
| `folders` | 100,000 | 41.001 | 0.001 | 41.000 | 99.997% |
| `no_match` | 100,000 | 54.800 | 13.805 | 40.996 | 74.809% |
| `hide_first` | 99,999 | 54.799 | 44.319 | 10.480 | 19.125% |
| `hide_last` | 99,999 | 54.799 | 44.323 | 10.477 | 19.118% |
| `hide_most` | 1,000 | 0.461 | 0.461 | 0.000 | 0.000% |
| `annotate_first` | 100,000 | 54.799 | 44.319 | 10.480 | 19.125% |
| `annotate_last` | 100,000 | 54.799 | 44.323 | 10.477 | 19.118% |
| `preannotated` | 100,000 | 59.965 | 50.422 | 9.543 | 15.914% |
| `search` | 20,000 | 67.471 | 26.475 | 40.996 | 60.761% |

Unchanged `tree`, `files`, `folders`, and `no_match` results share input storage in **all six candidate observations at every size**, versus none for the baseline. For the unchanged tree fixture at 100,000 rows, the observed row stride is 320 bytes, baseline result capacity is 134,348 rows, and the shared candidate/input capacity is 100,006 rows. The folder-view candidate projection delta is exactly **1,200 bytes**; its input rows remain live and are already included in the pre-projection baseline.

Changed-output cases still allocate their own arrays. Their smaller retained buffers come from bounding the requested final growth by the input size. `hide_most` excludes 99% of input rows and tests that the candidate does not reserve an entire large input for a small result. `preannotated` deliberately refreshes existing annotations and does not share the input buffer. Search may retain the visibility-stage saving even though its displayed result needs another array.

For `cache_hit`, priming occurs before the projection baseline. The incremental hit allocation is 0 bytes for baseline and 0 bytes for candidate; this does **not** mean the cache has no retained memory. Its separate fixture-inclusive retained allocation is:

| 100,000-row primed cache | Baseline MiB | Candidate MiB | Saved MiB | Paired reduction |
| --- | ---: | ---: | ---: | ---: |
| Fixture + cache + returned result | 145.708 | 104.712 | 40.996 | 28.136% |

### Timing and tradeoffs

**There is no general CPU or latency speedup claim.** The accepted run used a busy shared host (the initial one-minute load average was 16.14 with nine logical CPUs available). Timings vary widely and include candidate regressions. These observations are preserved rather than filtered away. Native measurements must evaluate this tradeoff before the PR is made ready.

For example, at 100,000 rows, `hide_last` has a paired median CPU change of +22.45% and wall-time change of +22.49%. CPU medians are 1,725.8 ms baseline and 2,214.3 ms candidate. Its min-max ranges overlap broadly, but the observed slowdown remains a tradeoff requiring native evaluation.

The following are median paired **CPU-time changes**; positive means the candidate used more CPU time. These are descriptive measurements from six pairs per cell, not confidence intervals or a causal estimate of the production app.

| Scenario | 1,000 rows | 10,000 rows | 100,000 rows |
| --- | ---: | ---: | ---: |
| `tree` | +46.47% | -0.89% | -17.32% |
| `files` | -7.73% | +27.73% | +5.24% |
| `folders` | -54.89% | -63.68% | -54.62% |
| `no_match` | -1.94% | +18.83% | -20.00% |
| `hide_first` | +5.50% | -4.18% | -19.02% |
| `hide_last` | -0.63% | -1.20% | +22.45% |
| `hide_most` | -5.39% | -25.77% | -4.46% |
| `annotate_first` | -17.16% | +12.02% | +6.20% |
| `annotate_last` | +18.21% | +13.48% | -11.03% |
| `preannotated` | -16.82% | +5.29% | -19.39% |
| `search` | +8.20% | -2.64% | +9.78% |
| `cache_hit` | -33.62% | +231.89% | -17.09% |

The [independent audit](evidence/linux-audit.md) lists full 100,000-row timing ranges and observed regressions; the [machine-readable summary](evidence/linux-summary.json) contains absolute CPU/wall medians, full min–max ranges, and paired changes for all 36 scenario/size groups. Cache-hit timings are especially small, so percentage differences can exaggerate a small absolute change. Awaited actor handoff and benchmark pool drainage are part of the timed call; fixture construction, media recognition, and diagnostic serialization are excluded.

### Correctness

| Gate | Result |
| --- | --- |
| Baseline release, all selected semantic tests | 44 test declarations passed |
| Candidate debug | 47 test declarations passed |
| Candidate release | 47 test declarations passed |
| Dedicated storage regression tests against baseline | Three test declarations fail as expected, with seven sharing assertions |
| Complete canonical output comparisons | All 17 cases at 257 rows are byte-identical |
| Measured output fingerprints | All 432 observations agree within their scenario and size |
| Provenance | Original sources, staged sources, and executable hashes verified before/after |

The new test file adds 18 test declarations: 15 semantic and three storage tests, including parameterized boundary cases. Coverage includes first/middle/last changes, both row-exclusion paths, all-hidden/empty results, folder inheritance, stale annotations, COW isolation, cache/search changes, and cancellation before entry. Both NFC-to-NFD and NFD-to-NFC rule-ID changes check exact UTF-8 bytes in both reveal modes. Per-row cancellation checks are unchanged; no deterministic mid-loop cancellation injection is claimed.

### Evidence and reproduction record

- [Correctness receipt](evidence/linux-correctness.json) and [complete correctness archive](evidence/linux-correctness.tar.gz).
- [Measurement receipt and SHA-256 inventory](evidence/linux-measurements.json) and [complete measurement archive](evidence/linux-measurements.tar.gz).
- [All 36 statistical summaries](evidence/linux-summary.json) and [independent audit](evidence/linux-audit.md).

The measurement continuation reused the exact executable files from the completed correctness run. It did not rebuild or rerun tests. The archive contains the continuation driver, environment/host records, commands, all raw observations, source snapshots, completion receipts, and byte-identical copies of the correctness evidence. An independent audit recomputed all paired statistics and checked source/binary/archive hashes. The standard command below performs correctness and measurement together from a fresh checkout.

Concurrent draft [PR #112](https://github.com/Jagalite/illiquid/pull/112), from `perf/source-visibility-storage-20261023`, proposes overlapping visibility-loop logic. These are alternative proposals; reconcile their tests/evidence and retain one final implementation when integrating.

## Reproduction

Follow the repository's shared Kyoto build-queue policy when its mount is available. The isolated Linux environment used here did not have that mount; native qualification is scheduled on isolated GitHub-hosted macOS runners.

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
separate native app/test build on the research branch. Pull requests from this
research branch run the correctness gates and native integration tests.

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
