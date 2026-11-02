# Source-browser search: compact scratch storage

## Finding and qualification

Replacing the temporary array of complete matching rows with matching row
indices reduced requested allocation bytes for the measured 100,000-media,
two-ancestor broad search from **184,239,975 to 102,451,055 bytes per operation**
(**44.39%**). That removes 81,788,920 requested bytes per search. The cached
projection workload fell from **259,801,238 to 178,012,882 bytes per operation**
(**31.48%**).

These are **Linux component allocation-traffic measurements**. They are not
live heap, peak memory, resident memory, or macOS player-footprint measurements.
The allocation count is nearly unchanged; the optimization makes the temporary
buffers smaller rather than eliminating most allocation requests.

The uninstrumented Linux timing cohort also improved: the same broad search
had a **16.78% median paired wall-time reduction**, and cached projection
improved **11.01%**. All 16 nonblank scenarios favored the candidate in all six
pairs. Blank-query controls were slightly slower and are retained below.

The [Linux qualification job](https://github.com/Jagalite/illiquid/actions/runs/40636607350/job/122644913586)
completed successfully on October 28, 2026. The macOS component job in the same
workflow was still queued when this report was written. Native macOS timings,
the complete application build, and live UI/playback qualification are therefore
not claimed here. The PR also runs the repository's existing macOS workflows.

## Change

[SourceBrowserFilter.search](../Sources/IlliquidApp/UI/SourceBrowserFilter.swift)
previously used `rows.filter` to materialize complete matching
`SourceTreeDisplayRow` values, then traversed those values only to gather IDs and
ancestor IDs. Those rows carry URLs, names, recognition/visibility metadata,
ancestry, and row-kind data.

The replacement filters `rows.indices` into an `[Int]`, then looks up each
matching row in the immutable input while building the identity set. The scratch
buffer stays local to the search. The final output still contains complete rows.

For a fixed sequence of cancellation observations, both implementations select
the same indices in the same order, reserve the identity set from the same match
count, insert the same IDs and ancestors, and perform the same final input-order
filter. This preserves duplicate identities and each matching duplicate's
distinct ancestors, original ordering, metadata eligibility, Unicode matching,
query trimming, and folder behavior. Indices remain valid because the input
array is immutable. A concurrently arriving cancellation can occur at a different
position after any performance change; the actor retains its existing check
before publishing a result.

## Experiment and provenance

- Baseline: `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`.
- Measured candidate: `2cd7ea9b7fc80cfcea8d7b7dab5d9d5a26fc5ecd`.
- Host: GitHub-hosted Ubuntu 24.04, AMD EPYC 9V74, Linux x86_64, glibc 2.39,
  Swift 6.4. Timing and allocation processes were pinned to logical CPU 0.
- Existing [benchmark harness](../Benchmarks/SourceBrowserSearch/Harness.swift),
  unchanged for this investigation: 18 constructed workloads, 1,000–100,000
  media rows, zero/two/eight ancestor levels, broad/sparse/no-match/blank/Unicode/
  recognized-metadata queries, and cached actor projection.
- Timing: six balanced AB/BA fresh-process pairs per case, 216 observations.
  Calibration chooses a shared iteration count from the slower pilot, targeting
  approximately 120 ms; this is not a minimum interval for both variants.
- Allocation traffic: a separate instrumented Linux cohort with two balanced
  pairs per case, 72 observations. Instrumented elapsed times are excluded from
  timing claims. The existing meter counts successful intercepted `malloc`,
  `calloc`, and `realloc` requests and requested bytes; it does not cover every
  allocation API.

Only the production Filter source differs between paired builds. The baseline
reference is now configurable and resolved once to a full commit SHA for source
staging, the exact-source oracle, and environment receipts. The runner retains
its historical default for reproducing the previous ID-union investigation;
this follow-up explicitly selects current main to isolate the index-storage
change. Both variants compile the same current support sources and harness.
The follow-up evidence/documentation commit leaves the measured production and
benchmark source unchanged; its code hashes match the measured revision. It
also removes the temporary branch-specific push trigger used to qualify the
change before opening a PR.

Fixture construction, warmup, and full output equality checks are outside the
timed interval. Query processing, result construction, and a small result
checksum are inside it. Cached `project(rows:...)` additionally includes media
path normalization and thumbnail-candidate collection. Tree construction,
the outer `project(input:...)` call, filesystem I/O, SwiftUI rendering, typing,
decoding, frame delivery, and energy use are outside the experiment.

## Allocation results

| Operation / media rows / ancestor levels / query | Baseline requested B/op | Candidate requested B/op | Paired reduction |
|---|---:|---:|---:|
| search / 1000 / 2 / broad | 1,466,439 | 827,583 | 43.57% |
| search / 10000 / 2 / broad | 22,460,263 | 12,236,703 | 45.52% |
| search / 100000 / 2 / broad | 184,239,975 | 102,451,055 | 44.39% |
| search / 100000 / 8 / broad | 184,959,975 | 103,171,055 | 44.22% |
| search / 100000 / 2 / sparse | 15,616,295 | 14,977,439 | 4.09% |
| search / 100000 / 2 / none | 12,240,252 | 12,240,252 | 0.00% |
| project / 100000 / 2 / broad | 259,801,238 | 178,012,882 | 31.48% |

The main broad-search request count changes only from 306,040 to 306,039.
Its requested-byte counts are identical in both repetitions of each variant.
The 100,000-media/two-ancestor fixture contains 102,000 input rows because it
includes 2,000 folder rows.

The one-percent-match search reduces requested bytes by 638,856 per operation.
No-match and blank direct-search requested bytes are unchanged. Async projection
controls have small runtime fluctuations: no-match projection requested 596
more bytes in the candidate medians, and blank projection differed by 32 bytes.
These controls are not allocation-saving claims.

Sources: [allocation summary](../Benchmarks/SourceBrowserSearch/evidence/indices-20261028/linux/allocations/summary.json)
and [all 72 raw observations](../Benchmarks/SourceBrowserSearch/evidence/indices-20261028/linux/allocations/measurements.jsonl).

## Uninstrumented timing results

Positive reductions favor the candidate. The percentage is the median of the
six within-pair reductions, `100 * (baseline - candidate) / baseline`; it need
not equal the ratio of the two separately aggregated median times.

| Operation / media rows / ancestor levels / query | Baseline ms/op | Candidate ms/op | Paired wall reduction | Faster pairs |
|---|---:|---:|---:|---:|
| search / 1000 / 2 / broad | 1.408 | 1.305 | 7.24% | 6/6 |
| search / 10000 / 0 / broad | 13.415 | 12.275 | 8.03% | 6/6 |
| search / 10000 / 2 / broad | 14.953 | 13.595 | 9.11% | 6/6 |
| search / 100000 / 0 / broad | 180.258 | 148.411 | 17.46% | 6/6 |
| search / 100000 / 2 / broad | 200.428 | 164.707 | 16.78% | 6/6 |
| search / 100000 / 8 / broad | 243.932 | 210.223 | 13.10% | 6/6 |
| search / 100000 / 0 / sparse | 132.513 | 116.140 | 12.51% | 6/6 |
| search / 100000 / 2 / sparse | 146.098 | 128.544 | 12.15% | 6/6 |
| search / 100000 / 0 / none | 121.814 | 105.522 | 13.59% | 6/6 |
| search / 100000 / 2 / none | 124.708 | 108.255 | 13.66% | 6/6 |
| search / 100000 / 2 / blank | 0.000239 | 0.000245 | -2.31% | 0/6 |
| search / 10000 / 2 / metadata | 28.602 | 26.752 | 6.74% | 6/6 |
| search / 10000 / 2 / unicode | 17.167 | 16.041 | 6.07% | 6/6 |
| project / 100000 / 0 / broad | 289.447 | 262.324 | 9.29% | 6/6 |
| project / 100000 / 2 / broad | 319.000 | 283.853 | 11.01% | 6/6 |
| project / 100000 / 2 / sparse | 142.349 | 126.098 | 11.71% | 6/6 |
| project / 100000 / 2 / none | 124.278 | 107.101 | 13.92% | 6/6 |
| project / 100000 / 2 / blank | 0.006133 | 0.006643 | -4.42% | 1/6 |

The main nested search's paired CPU reduction was **16.78%**, and cached
projection's was **11.01%**, consistent with wall time on this host. Faster
no-match searches have unchanged allocation bytes, so the timing effect cannot
be attributed solely to reduced allocation volume; iteration and value-copying
code also changed.

Blank search's separate medians differ by approximately 5.88 ns, and blank
cached projection by 0.509 microseconds. Those paths take the existing empty
query/cache-return branches. These small unfavorable observations are retained;
the results do not establish a universal speedup. No observations were removed
as outliers, and no native speedup is inferred from the Linux results.

Sources: [timing summary](../Benchmarks/SourceBrowserSearch/evidence/indices-20261028/linux/timing/summary.json)
and [all 216 raw observations](../Benchmarks/SourceBrowserSearch/evidence/indices-20261028/linux/timing/measurements.jsonl).

## Behavioral validation and independent audit

The existing [regression suite](../Tests/IlliquidAppTests/SourceBrowserSearchTests.swift)
passed against baseline and candidate in both debug and release: **nine test
functions per configuration**, four runs. Coverage includes explicit duplicate
IDs/ancestors and output order, recognized-media fields, Unicode, visibility
annotations, thumbnails and media paths, cache reuse, episode grouping,
pre-cancellation, and 416 seeded differential queries. The change reuses this
coverage without adding an implementation-specific test.

Every benchmark process checked complete output equality against the exact
baseline source. Cached projections additionally checked thumbnails, media
paths, hidden/rule counts, and visibility-cache reuse. Paired fingerprints,
checksums, row counts, and iteration counts matched.

An independent audit fetched the job log and repository sources separately,
recomputed all summary statistics from the 288 raw observations, checked AB/BA
ordering and parity, and verified source/test/harness hashes, 18 extracted
support declarations, the reassembled support file, and the baseline oracle.
See the [audit](../Benchmarks/SourceBrowserSearch/evidence/indices-20261028/linux/audit.json)
and [evidence index](../Benchmarks/SourceBrowserSearch/evidence/indices-20261028/README.md).

The local execution environment failed to start. The shared Kyoto queue was
unavailable in this session; builds ran directly on isolated GitHub-hosted
runners. Compilation and component execution are established by CI receipts.
They do not constitute live UI qualification.

## Reproduce

Use Python 3.10+, Git containing the baseline, and Swift 6.1+ with its bundled
Testing module. No external Swift packages are required for the component.

```sh
baseline=ea2ff568237e2667f7b1aeee67b11a44ebe95b72
for configuration in debug release; do
  python3 Scripts/test-source-browser-search.py \
    --configuration "$configuration" --baseline-ref "$baseline" \
    --output "/tmp/search-indices-baseline-$configuration"
  python3 Scripts/test-source-browser-search.py \
    --configuration "$configuration" \
    --output "/tmp/search-indices-candidate-$configuration"
done

python3 Benchmarks/SourceBrowserSearch/run.py \
  --baseline-ref "$baseline" --pairs 6 --target-ms 120 \
  --output /tmp/search-indices-timing

# Linux/glibc only; keep instrumentation separate from timing.
python3 Benchmarks/SourceBrowserSearch/run.py \
  --baseline-ref "$baseline" --allocations --pairs 2 \
  --output /tmp/search-indices-allocations
```

Use new or empty output directories. On Linux, add `--cpu N` with an available
logical CPU to reproduce affinity. On a workstation with Kyoto available,
submit build/test/benchmark commands through the shared queue as required by
[AGENTS.md](../AGENTS.md). The [benchmark README](../Benchmarks/SourceBrowserSearch/README.md)
describes the retained receipts, output boundaries, and case selection.
