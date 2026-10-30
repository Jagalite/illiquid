# Source-browser search row storage

## Finding and qualification

The complete Linux CI comparison supports retaining this small change. Broad
search of 100,000 media rows plus two levels of ancestor rows requested **44.39%
fewer allocation bytes** and improved median paired wall time by **15.53%**.
The complete cached projection for the same fixture requested **31.48% fewer
bytes** and improved median paired wall time by **10.72%**. Both timing cases
favored the candidate in all six pairs.

These are component results on Ubuntu 24.04, an AMD EPYC 7763 runner, and Swift
6.4.1. They establish lower allocation traffic for these prepared-row workloads,
not a measured reduction in whole-player RSS or a native macOS speed claim.

[CI run 40635349272](https://github.com/Jagalite/illiquid/actions/runs/40635349272)
qualified the production and benchmark sources at
[`e9dad9dc39ac96c6796ebffed970d809d94e28c4`](https://github.com/Jagalite/illiquid/commit/e9dad9dc39ac96c6796ebffed970d809d94e28c4).
The Linux job completed **216 uninstrumented timing observations** and **72
separate allocation observations**, covering all 18 predefined cases. Every
process passed its complete-output checks; paired fingerprints and checksums
matched. Both cohorts verified that the only differing compiled source was
`SourceBrowserFilter.swift`.

| Qualification | Result |
|---|---|
| Linux CI baseline/candidate, debug/release | All 9 existing Swift Testing functions passed in each of the four builds |
| Local Linux Swift 6.3.2 baseline/candidate, debug/release | All 9 functions passed in each build |
| Complete Linux CI timing and allocation matrices | Passed; 216 timing and 72 allocation observations |
| macOS component CI | Queued at report preparation; no native result is claimed |
| Full application and live UI/playback | Outside this component qualification |

The existing tests include 416 seeded query/input comparisons, plus explicit
duplicate identities, ancestors, metadata fields, Unicode, blank queries,
cancellation and actor-projection cases. They already exercise the behavior
risks of this change, so no implementation-specific tests were added.

## Problem and change

Source-browser search used a temporary array of complete `SourceTreeDisplayRow`
values to remember which rows matched a query. Its next pass needed only those
rows' identities and ancestor identities, before a final pass selected the rows
to return. Broad queries therefore allocated and populated an unnecessary row
buffer alongside the prepared input and the required output.

The candidate stores matching indices instead. It reads the original rows when
building the visible-identity set, reserving that set for the same match count as
before. The final row filter is unchanged. This removes temporary full-row storage
and its associated element ownership traffic without introducing a persistent
cache or changing the search predicates.

The baseline is commit `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`. The production
change is limited to
[`SourceBrowserFilter.search`](../Sources/IlliquidApp/UI/SourceBrowserFilter.swift).
The baseline is the main-branch implementation immediately before this change;
it already includes the earlier flattened-ID-array optimization described in
[`SOURCE_BROWSER_SEARCH_PERFORMANCE.md`](SOURCE_BROWSER_SEARCH_PERFORMANCE.md).
That earlier saving is not part of this comparison.

## Production path and preserved behavior

[`SourcesSidebar.refreshVisibleRows`](../Sources/IlliquidApp/UI/SourcesSidebar.swift)
captures the current query and source-tree input, then invokes the
`SourceBrowserFilter` actor. The actor reuses its tree and visibility caches where
possible, runs search, and constructs the returned projection. The sidebar
publishes those rows and passes the projection's thumbnail candidates and media
paths to the thumbnail scheduler. The changed search is on this normal browser
path, including query changes over an already prepared library.

The implementation preserves:

- The whitespace-trimmed query and immediate return for an empty query.
- A cancellation check before each row's matching predicate.
- The existing localized display-name, filename, section, catalog-ID and context
  matching rules, including the requirement for recognized metadata before the
  additional fields are searched.
- Exclusion of message and section rows from direct matching.
- The union of every matching row's identity and explicit ancestor identities.
- The final input-order filter, including nonmatching rows with a matching
  duplicate identity and ancestor rows of any kind.

Collecting only matching rows for the final result would violate those identity
and ancestor rules. The candidate changes only the temporary representation used
between matching and identity collection.

## Allocation results

The following figures are median **intercepted allocation-request bytes per
operation**. They sum successful `malloc`, `calloc` and `realloc` requests;
they do not represent simultaneously live memory. Case names encode operation,
media-row count, ancestor depth and matching scenario. For example,
`search/100000/2/broad` has 100,000 media rows and 2,000 folder rows.

| Workload | Baseline requested bytes/op | Candidate requested bytes/op | Reduction |
|---|---:|---:|---:|
| `search/10000/2/broad` | 22,460,263 | 12,236,703 | 45.52% |
| `search/100000/0/broad` | 183,999,975 | 102,211,055 | 44.45% |
| `search/100000/2/broad` | 184,239,975 | 102,451,055 | 44.39% |
| `project/100000/0/broad` | 258,057,270 | 176,268,318 | 31.69% |
| `project/100000/2/broad` | 259,801,270 | 178,012,350 | 31.48% |

In the local Swift 6.3.2 probe, a complete row had a 320-byte stride and an index
had an 8-byte stride. The change also avoids storing the row's reference-bearing
fields in the temporary match array. String and array contents were already
shared through value semantics; this is not a claim that their full backing
storage was deep-copied. Array growth means cumulative requested bytes differ
from simply multiplying the number of matches by an element stride.

Absent and blank queries requested the same number of allocation bytes in both
versions. Sparse queries saved less, as expected from their smaller match arrays.

## Complete Linux result matrix

Timings below are separate medians from the uninstrumented cohort. Percentage
columns use the median of within-pair reductions, so a percentage need not equal
the ratio of the two displayed medians. Positive values favor the candidate.
All observations are retained, including the unfavorable blank-projection
control. CPU timing is recorded separately in the retained summaries and raw data.

| Case | Baseline ms/op | Candidate ms/op | Paired wall reduction | Faster pairs | Requested-byte reduction |
|---|---:|---:|---:|---:|---:|
| `search/1000/2/broad` | 1.946 | 1.819 | 6.65% | 6/6 | 43.57% |
| `search/10000/0/broad` | 20.640 | 18.215 | 10.75% | 6/6 | 45.57% |
| `search/10000/2/broad` | 22.301 | 20.045 | 9.79% | 6/6 | 45.52% |
| `search/100000/0/broad` | 276.599 | 232.050 | 15.84% | 6/6 | 44.45% |
| `search/100000/2/broad` | 300.092 | 253.448 | 15.53% | 6/6 | 44.39% |
| `search/100000/8/broad` | 353.581 | 311.267 | 12.21% | 6/6 | 44.22% |
| `search/100000/0/sparse` | 178.214 | 162.653 | 8.60% | 6/6 | 4.79% |
| `search/100000/2/sparse` | 190.956 | 174.054 | 8.77% | 6/6 | 4.09% |
| `search/100000/0/none` | 164.554 | 147.199 | 10.34% | 6/6 | 0.00% |
| `search/100000/2/none` | 168.651 | 151.205 | 10.08% | 6/6 | 0.00% |
| `search/100000/2/blank` | 0.000353 | 0.000351 | 0.90% | 5/6 | 0.00% |
| `search/10000/2/metadata` | 40.000 | 37.951 | 5.27% | 6/6 | 42.07% |
| `search/10000/2/unicode` | 23.992 | 22.059 | 7.66% | 6/6 | 45.52% |
| `project/100000/0/broad` | 422.301 | 369.491 | 12.61% | 6/6 | 31.69% |
| `project/100000/2/broad` | 456.169 | 406.073 | 10.72% | 6/6 | 31.48% |
| `project/100000/2/sparse` | 191.354 | 171.773 | 10.24% | 6/6 | 3.90% |
| `project/100000/2/none` | 168.099 | 149.098 | 11.39% | 6/6 | 0.00% |
| `project/100000/2/blank` | 0.007454 | 0.007533 | -1.46% | 1/6 | 0.00% |

The unchanged blank-query cached projection measured
0.007454 ms versus
0.007533 ms, a **1.46%
unfavorable paired difference** on a microsecond-scale control. Its requested
allocation bytes were unchanged. This is not evidence of a general improvement
to the blank-query path. Nonblank cases favored the candidate in all six timing
pairs on this host; another platform or live UI workload still needs its own
measurement.

## Retained evidence

The [evidence index](../Benchmarks/SourceBrowserSearch/evidence/row-storage/README.md)
links the complete CI evidence, source/host provenance and local test receipts. The CI archive retains all 105 text files from artifact
`12793622337`, including both raw measurement files, every build/test log,
compiled source snapshots, hashes and completion markers. The downloaded ZIP's
SHA-256 is
`00e749b43ea1ef52722ab871d93ec966af7f23531121d198e27a0098589e93ab`.
The retained gzip JSON archive has its own hash in `provenance.json`.

A preliminary local allocation run exhausted the shared workspace disk after
60 of 72 records. Its original raw records, truncated summary and explicit
`aborted.json` are retained separately and labeled **nonprimary evidence**.
No local uninstrumented timing run was started. All published performance tables
above use the completed CI cohorts; no partial run was presented as complete.

## Method

The experiment reuses
[`Scripts/test-source-browser-search.py`](../Scripts/test-source-browser-search.py)
and the existing
[`SourceBrowserSearch` benchmark](../Benchmarks/SourceBrowserSearch/README.md).
The runner's explicit `--baseline-ref` selects the commit above instead of the
older experiment's default baseline.

The harness stages the complete production filter and tree-input files, actual
portable core dependencies, and verbatim portable declarations from the larger
app source files. It does not replace row models or search logic with a simulation.
Baseline and candidate share the support sources and driver; only the filter
source differs. Production modules and the driver compile separately. Source,
executable, harness and toolchain receipts identify the code measured.

Prepared synthetic row sets exercise broad, sparse, absent and blank queries,
with Unicode and recognized-metadata fallback controls. Both direct search and
cached actor projection are measured. Projection includes the subsequent
thumbnail/path construction, so its results cover more work than search alone.
Input construction, oracle evaluation, warmup and full output equality checks
are outside the timed region. Every final row array must equal the exact search
method extracted from the selected baseline. Projection also checks metadata,
thumbnail candidates, media paths and visibility-cache reuse.

Uninstrumented timing uses six pairs, alternating process order AB/BA. Calibration
selects a common iteration count for both variants toward 120 ms per observation.
Wall and process CPU times are recorded separately. A separate two-pair
Linux/glibc cohort uses the existing allocation meter to record intercepted
successful `malloc`, `calloc` and `realloc` requests and their requested bytes.
Instrumented wall times are not evidence for the timing result. All observations,
including unfavorable controls, belong in the report; none are removed as
outliers.

## Reproduce

Requirements are Python 3.10 or newer, Git containing the selected baseline, and
Swift 6.1 or newer with its bundled Testing module. Allocation instrumentation
also requires a C compiler and glibc Linux. The component package downloads no
external Swift dependencies. Use new or empty output directories.

Run behavior checks for both revisions and build configurations:

```sh
for configuration in debug release; do
  python3 Scripts/test-source-browser-search.py \
    --baseline-ref ea2ff568237e2667f7b1aeee67b11a44ebe95b72 \
    --configuration "$configuration" \
    --output "/tmp/source-search-row-storage/baseline-$configuration"
  python3 Scripts/test-source-browser-search.py \
    --configuration "$configuration" \
    --output "/tmp/source-search-row-storage/candidate-$configuration"
done
```

Run the separate timing and allocation cohorts:

```sh
python3 Benchmarks/SourceBrowserSearch/run.py \
  --baseline-ref ea2ff568237e2667f7b1aeee67b11a44ebe95b72 \
  --pairs 6 --target-ms 120 \
  --output /tmp/source-search-row-storage/timing

python3 Benchmarks/SourceBrowserSearch/run.py \
  --baseline-ref ea2ff568237e2667f7b1aeee67b11a44ebe95b72 \
  --allocations --pairs 2 \
  --output /tmp/source-search-row-storage/allocations
```

All commands accept `--swift /path/to/swift` to select a toolchain. Benchmark
`--case` options can select exact workloads from its predefined matrix. On a
machine with the shared Kyoto queue, submit compiling commands through that queue
as required by [`AGENTS.md`](../AGENTS.md). The local Linux environment has no
Kyoto installation, so its isolated component builds run directly.

## Interpretation and limits

Allocation-request bytes describe cumulative allocation traffic during the
measured operation. They do not measure live heap, peak memory, resident memory,
physical footprint, or every allocator API. A smaller temporary element buffer
explains a mechanism; it is not itself an observed reduction in whole-player RSS.

The rows and their metadata are constructed fixtures. Large cases are stress
workloads, not a claim about the size or composition of a typical user's library.
No filesystem scan, video decoding, actual typing, SwiftUI rendering or playback
is included. The original input, visible-identity set and required result still
exist, and unchanged Foundation matching/projection costs can dominate timing.

Linux component results establish behavior and resource effects for that host
and toolchain. They do not qualify live macOS interaction, native playback or
Apple-platform memory behavior. Any native CI results must be reported separately
from live UI/playback qualification.
