# Source browser search: temporary ID allocation cost

## Finding

The retained evidence supports a small allocation optimization with repeated
favorable native results for two measured workloads. On macOS, 1,000-media
nested search improved **11.54% and 11.38%** by median paired wall time in the
two runs. Cached projection of 100,000 media rows with two ancestor levels
improved **8.35% and 4.49%**. Each workload favored the candidate in **10 of 12
within-run pairs**, with favorable paired CPU medians in both runs.

The native result is workload-dependent. Direct search of the 100,000-media,
two-level tree remained inconclusive (**0.01% and 0.97%, 6/12 favorable
pairs**). Flat projection and the eight-level search stress case disagreed
between runs. These results do not establish a general native search speedup.

The Linux cohort consistently improved broad searches and isolated the intended
allocation effect: the 100,000-media two-level search made **39.52% fewer
intercepted allocation requests** and requested **13.85% fewer bytes**, with
**10.32% less paired wall time**. Allocation counts apply to the measured Linux
runtime; native allocations were not instrumented.

The PR retains the six-line production diff, nine regression test functions,
reproduction tooling, and all completed qualification evidence. Behavior checks
passed for both implementations in debug and release on both platforms. The
complete native app build and unfiltered release suite also passed under their
CI configuration. Detailed results and their limits follow.

## Scope

This investigation examines complete source-browser searches and cached
background projection of prepared source rows. The original search is pinned to
`68274d1b09dcc866296321a5a8858efc297c4f19`. Its Filter file is also byte-for-byte
identical to main `33fff16155c3472960f88e04c72dfdfdefd56dcf`, so the optimization
applies to the current search implementation.

The production change is five added lines and one removed line in
[SourceBrowserFilter.search](../Sources/IlliquidApp/UI/SourceBrowserFilter.swift).
It replaces `Set(matchingRows.flatMap { [$0.id] + $0.ancestorIDs })` with a set
reserved from the actual number of matches, followed by direct ID insertion and
ancestor union. It introduces no cache or persistent state.

## Why this area

[SourcesSidebar](../Sources/IlliquidApp/UI/SourcesSidebar.swift) requests a
background projection when search text changes. The actor reuses prepared rows
and its visibility projection when their inputs are unchanged. A nonblank query
still runs the complete search and constructs the resulting projection.

The old search constructs an array for every matching row, concatenates its ID
and all ancestor IDs, flattens those arrays, and then constructs a set. Sibling
matches repeatedly copy the same ancestors. The result only requires unique
identities. Direct union removes these intermediate arrays while retaining the
same membership calculation. The number of IDs examined is unchanged; the
optimization removes allocation and copying work rather than a tree traversal.

Reserving from the actual match count avoids reserving for every input row on a
sparse or unsuccessful search. The set may still grow to accommodate distinct
ancestors. The measurements include that cost.

## Behavior preservation

For matching rows M, both implementations construct exactly
`union({row.id} union row.ancestorIDs for row in M)`. Both return the original
input rows whose IDs belong to that set. Keeping the final input-order filter
preserves order and duplicate rows. Every matching duplicate identity contributes
its own ancestors.

The matching predicate, locale-aware comparison, metadata eligibility, query
trimming, cancellation checks, visibility logic, and projection construction are
unchanged. A directly matching folder includes its listed ancestors; it does
not expand its descendants. Message and section rows can appear through an ID
match or ancestor membership, but do not directly match the search predicate.

[SourceBrowserSearchTests](../Tests/IlliquidAppTests/SourceBrowserSearchTests.swift)
adds nine Swift Testing test functions, including a three-case whitespace test.
Explicit expectations cover duplicate rows and ancestor lists, folder behavior,
recognized-media fields, Unicode matching, visibility metadata and cache reuse,
media grouping and episode order, and deterministic cancellation. A seeded
differential test performs 416 query comparisons over 32 generated row sets.
The same tests are run against the original and candidate Filter in debug and
release.

## Experiment

The [benchmark README](../Benchmarks/SourceBrowserSearch/README.md) contains
reproduction commands and the detailed measurement boundaries. The runner
stages the complete production Filter/Input/core files and verbatim portable
declarations from AppModel and SourcesSidebar. It calls them from a separately
compiled executable. The only source difference between paired builds must be
the Filter file; matching hashes for all other compiled sources, the harness,
the old-source oracle, and the final package manifest are enforced before timing.

The default matrix contains 18 cases. Constructed libraries contain 1,000,
10,000, or 100,000 media rows, with zero, two, or eight ancestor levels and 100
sibling media rows per branch. Nested fixtures contain actual folder rows and
nested directory/file paths. Eight levels are a stress case, not a claim about
a typical user's library.

Queries include broad matches, one-percent matches, no matches, whitespace,
Unicode, and recognized-media filename fallback. Search and the cached actor
`project(rows:...)` operation are measured separately. The latter includes query
processing, standardized media paths, and thumbnail-candidate collection. It
does not include the outer `project(input:...)` cache-key comparison or source
tree construction. Default tree mode is measured; media grouping has correctness
coverage but is outside the timing matrix.

Each uninstrumented cohort uses six balanced AB/BA pairs per case, with fixed
case order and a fresh process per observation. Calibration chooses one shared
iteration count for both variants, targeting approximately 120 ms where possible.
Fixture construction, exact old-source oracle evaluation, warmup, and full
result validation are outside timing. A small result-consumption checksum is
inside timing and is not subtracted. Wall and process CPU time are recorded
separately. All 216 observations are retained, including unfavorable pairs.
For each pair, the time reduction is
`100 × (baseline − candidate) / baseline`; tables report the median of those
six reductions. This need not equal the ratio of the two displayed medians.

Every process checks the complete row array against the pinned original search;
projection also checks paths, thumbnails, counts, and cache reuse. Paired stable
fingerprints, checksums, row counts, and iteration counts must match.

The separate Linux allocation cohort uses two balanced pairs per case and
retains all 72 observations. The existing glibc meter counts successful
intercepted `malloc`, `calloc`, and `realloc` calls and their requested bytes.
It does not cover every allocation API or measure live heap, peak memory, RSS,
GPU memory, or macOS footprint. Instrumented elapsed times are excluded from
the timing claims.

## Qualification results

### Native macOS: first cohort

The first native job passed on October 19, 2026 on an Apple M1 virtual runner,
macOS 26.6.2, using Apple Swift 6.3.3 from Xcode 26.6. It tested the same PR merge
`f9ed5ee80bcf7c62f330a46306e21367b509b639` and identical source/harness inputs
as Linux. All four baseline/candidate debug/release runs passed nine tests each
(36 reported tests), and all 216 timing observations passed their result checks.

**The first native timing cohort is mixed.** The 1,000-media two-level broad
search improved 11.54% by median paired wall time, with 6/6 favorable pairs.
The 100,000-media eight-level stress search improved 6.77% with 5/6 favorable
pairs, and the two-level cached projection improved 8.35% with 5/6 favorable
pairs. However, the primary 100,000-media two-level search has a median paired
wall reduction of only 0.01% and 3/6 favorable pairs. Its pair reductions span
−47.97% to +43.27%.

The separate medians for that primary search are 290.649 ms and 265.037 ms, but
their ratio would imply a benefit unsupported by the paired observations.
The report therefore does not claim an 8.81% native search improvement from
those two numbers. Its paired CPU median is 3.70%, which also does not establish
a stable wall-time improvement. Flat broad projection has a −6.26% wall result
with 2/6 favorable pairs, versus +1.08% in paired CPU time. Unchanged blank and
no-match controls also fluctuate. The 10,000-media flat broad search is slower
in both wall time (−4.55%, 2/6 favorable pairs) and CPU time (−3.95%, 1/6
favorable pairs), so the unfavorable native results cannot all be described as
wall-clock scheduling noise. All of these observations are retained.

The primary 100,000-media search and projection calibrated to one timed
operation per native process after one warmup. Their six pairs are six process
observations per variant, not six batches averaging many large searches.

To assess this variability, exactly one additional native run was requested
before viewing its results, with no source, harness, case, iteration-target, or
pair-count changes. The [replication plan](../Benchmarks/SourceBrowserSearch/evidence/replication-plan.json)
records that decision. Both completed native cohorts are shown separately below;
the secondary combined comparison uses only within-run pairs.

| Operation | Media rows | Ancestors | Query | Baseline ms | Candidate ms | Paired reduction | Faster pairs |
|---|---:|---:|---|---:|---:|---:|---:|
|search|1,000|2|broad|2.811|2.504|11.54%|6/6|
|search|10,000|0|broad|24.442|23.954|-4.55%|2/6|
|search|10,000|2|broad|29.137|29.734|0.93%|3/6|
|search|100,000|0|broad|322.260|317.708|6.26%|3/6|
|search|100,000|2|broad|290.649|265.037|0.01%|3/6|
|search|100,000|8|broad|363.131|317.413|6.77%|5/6|
|search|100,000|0|sparse|158.470|151.044|3.42%|4/6|
|search|100,000|2|sparse|168.261|168.580|-0.19%|2/6|
|search|100,000|0|none|203.485|195.302|3.69%|4/6|
|search|100,000|2|none|165.221|193.596|-5.35%|2/6|
|search|100,000|2|blank|0.000260|0.000274|-9.34%|1/6|
|search|10,000|2|metadata|38.614|38.682|1.83%|5/6|
|search|10,000|2|unicode|23.437|21.808|7.80%|5/6|
|project|100,000|0|broad|513.302|532.437|-6.26%|2/6|
|project|100,000|2|broad|563.788|523.893|8.35%|5/6|
|project|100,000|2|sparse|169.223|167.049|-0.15%|3/6|
|project|100,000|2|none|143.244|143.411|1.01%|4/6|
|project|100,000|2|blank|0.018276|0.016194|11.22%|4/6|

Sources: [first native summary](../Benchmarks/SourceBrowserSearch/evidence/macos/timing/summary.json),
[all 216 measurements](../Benchmarks/SourceBrowserSearch/evidence/macos/timing/measurements.jsonl),
[environment](../Benchmarks/SourceBrowserSearch/evidence/macos/timing/environment.json),
and the [exact native archive](../Benchmarks/SourceBrowserSearch/evidence/macos/qualification.zip).
Its SHA-256 matches GitHub artifact `12220902097`:
`2eff3efa42e20d25f1d09a5210fe8012e404815239af784058ddf6c872da621d`.

### Native replication

The single predeclared repeat completed successfully in native job
`118305093598` of the same workflow run, attempt 2. It used the same PR merge,
compiler, virtual Apple M1 host type, cases, pair count, target duration, and
source/harness hashes. Each variant recalibrated on its new runner as prescribed
by the unchanged harness; the shared iteration count within each comparison was
preserved. The four test configurations again reported nine passing tests each,
and all 216 timing observations passed their result checks.

The repeat corroborated the small nested-search result (**11.38%, 4/6 favorable
pairs**) and the large nested cached-projection result (**4.49%, 5/6**). Their
paired CPU reductions were 7.27% and 4.50%, respectively. The primary large
nested direct search remained inconclusive (**0.97%, 3/6**), as in the first run.

The adverse flat-search and flat-projection results from the first run did not
recur: their repeat wall reductions were 3.72% and 3.83%. This disagreement is
retained and does not establish a benefit in either flat case. The deep-tree
stress search changed direction to **−4.18% wall time, 2/6 favorable pairs**,
although its CPU reduction remained positive at 4.36%. Sparse, unsuccessful,
and blank searches still provide no useful performance claim.

| Operation | Media rows | Ancestors | Query | Baseline ms | Candidate ms | Paired reduction | Faster pairs |
|---|---:|---:|---|---:|---:|---:|---:|
| search | 1,000 | 2 | broad | 2.825 | 2.506 | 11.38% | 4/6 |
| search | 10,000 | 0 | broad | 26.856 | 25.430 | 3.72% | 5/6 |
| search | 10,000 | 2 | broad | 37.443 | 30.273 | 16.63% | 6/6 |
| search | 100,000 | 0 | broad | 348.518 | 352.306 | 5.94% | 4/6 |
| search | 100,000 | 2 | broad | 283.636 | 282.187 | 0.97% | 3/6 |
| search | 100,000 | 8 | broad | 341.198 | 357.142 | -4.18% | 2/6 |
| search | 100,000 | 0 | sparse | 180.735 | 194.120 | -5.28% | 2/6 |
| search | 100,000 | 2 | sparse | 198.173 | 220.687 | -5.61% | 3/6 |
| search | 100,000 | 0 | none | 177.897 | 177.714 | 1.12% | 3/6 |
| search | 100,000 | 2 | none | 159.840 | 158.058 | -1.01% | 3/6 |
| search | 100,000 | 2 | blank | 0.000291 | 0.000290 | -1.41% | 3/6 |
| search | 10,000 | 2 | metadata | 44.177 | 43.751 | 0.80% | 3/6 |
| search | 10,000 | 2 | unicode | 24.660 | 25.087 | 0.73% | 3/6 |
| project | 100,000 | 0 | broad | 555.686 | 550.399 | 3.83% | 4/6 |
| project | 100,000 | 2 | broad | 528.799 | 510.049 | 4.49% | 5/6 |
| project | 100,000 | 2 | sparse | 171.432 | 170.881 | -0.39% | 3/6 |
| project | 100,000 | 2 | none | 148.299 | 148.760 | 1.43% | 3/6 |
| project | 100,000 | 2 | blank | 0.015374 | 0.015399 | 0.42% | 3/6 |

Sources: [repeat summary](../Benchmarks/SourceBrowserSearch/evidence/macos-repeat/timing/summary.json),
[all 216 repeat observations](../Benchmarks/SourceBrowserSearch/evidence/macos-repeat/timing/measurements.jsonl),
[repeat environment](../Benchmarks/SourceBrowserSearch/evidence/macos-repeat/timing/environment.json),
and [exact repeat archive](../Benchmarks/SourceBrowserSearch/evidence/macos-repeat/qualification.zip).
The archive SHA-256 matches GitHub artifact `12221344849`:
`a0d9b69afe4c921ddb7e4bf0fba1315a9e6b270ba8bfd6f0d8e3dc27a38890a3`.

A secondary descriptive comparison pools each case's 12 within-run paired
reductions. It never pairs observations from different runs or pools native
and Linux timings. It does not override disagreement between the two native
cohorts. Selected results show the repeated benefits and key counterexamples;
the [complete native combined record](../Benchmarks/SourceBrowserSearch/evidence/combined-native.json)
contains all 18 cases with separate-cohort statistics.

| Workload | Combined paired wall reduction | Faster wall pairs | Combined paired CPU reduction |
|---|---:|---:|---:|
| Nested search, 1,000 media | 11.54% | 10/12 | 8.37% |
| Nested search, 100,000 media | 0.97% | 6/12 | 1.03% |
| Eight-level search, 100,000 media | 3.74% | 7/12 | 7.53% |
| Flat cached projection, 100,000 media | -1.30% | 6/12 | 1.08% |
| Nested cached projection, 100,000 media | 5.06% | 10/12 | 5.01% |

### Native application validation

The existing [native lifecycle job](https://github.com/Jagalite/illiquid/actions/runs/39320261271/job/118292176099)
passed on the same tested PR merge. It built the complete native app dependency
graph, linked `Illiquid` and `IlliquidPackageTests`, and ran the unfiltered root
package command `swift test --force-resolved-versions -c release --no-parallel`.
The final Swift Testing aggregate reports **1,397 tests in 193 suites passing**;
the separate XCTest aggregate reports **68 tests with zero failures**. All nine
new search test functions ran and passed in this actual application suite.

The job prepared its short H.264/AAC packet-ownership fixture and ran that
fixture test. Optional native fixture directories, broader codec coverage, and
long-duration playback checks were not enabled; the log includes explicit
skips and `NOT RUN` markers. This establishes the app build and package-suite
result under the CI configuration, not interactive playback or every optional
integration matrix. The existing focused-core, native presentation, geometry,
and non-decoding component checks also passed.

Sources: [validation receipt](../Benchmarks/SourceBrowserSearch/evidence/native-validation/receipt.json)
and [complete compressed job log](../Benchmarks/SourceBrowserSearch/evidence/native-validation/native-lifecycle.log.gz).

### Linux timing

The replacement Linux job passed on October 19, 2026, using Swift 6.4 on a
GitHub-hosted Ubuntu 24.04 runner with an Intel Xeon Platinum 8370C processor.
The runner and its child processes were pinned to logical CPU 0. The recorded
image version is `20261012.334.1`; the tested PR merge revision is
`f9ed5ee80bcf7c62f330a46306e21367b509b639`.

Baseline and candidate passed all nine test functions in both debug and release
(36 reported tests across the four executions). The complete 18-case timing
matrix and separate allocation matrix finished with all equality checks passing.

For 100,000 media rows and two ancestor levels, the complete search medians
were **330.930 ms → 297.025 ms**, a **33.905 ms** difference. The median
within-pair reduction was **10.32%**, with all six pairs favoring the candidate.
The cached projection medians were **528.881 ms → 494.129 ms**; its paired
reduction was **7.05%**, also favorable in all six pairs. Process CPU results
agreed closely: 10.32% and 7.05% median paired reductions, respectively.

The complete wall-time matrix follows. All times are milliseconds per operation.
Positive paired reductions favor the candidate; negative values are regressions.
The statistic is the median of the six within-pair reductions defined above.

| Operation | Media rows | Ancestors | Query | Baseline ms | Candidate ms | Paired reduction | Faster pairs |
|---|---:|---:|---|---:|---:|---:|---:|
| search | 1,000 | 2 | broad | 2.224 | 1.942 | 12.41% | 6/6 |
| search | 10,000 | 0 | broad | 22.912 | 21.127 | 8.67% | 6/6 |
| search | 10,000 | 2 | broad | 27.420 | 23.306 | 14.34% | 6/6 |
| search | 100,000 | 0 | broad | 286.064 | 258.556 | 9.65% | 6/6 |
| search | 100,000 | 2 | broad | 330.930 | 297.025 | 10.32% | 6/6 |
| search | 100,000 | 8 | broad | 442.341 | 378.700 | 14.53% | 6/6 |
| search | 100,000 | 0 | sparse | 177.956 | 177.674 | 0.80% | 3/6 |
| search | 100,000 | 2 | sparse | 189.119 | 188.930 | 0.77% | 4/6 |
| search | 100,000 | 0 | none | 162.017 | 164.165 | -1.33% | 1/6 |
| search | 100,000 | 2 | none | 167.861 | 168.054 | 0.12% | 3/6 |
| search | 100,000 | 2 | blank | 0.000406 | 0.000410 | -0.19% | 2/6 |
| search | 10,000 | 2 | metadata | 45.848 | 41.366 | 9.33% | 6/6 |
| search | 10,000 | 2 | unicode | 29.795 | 26.450 | 11.94% | 6/6 |
| project | 100,000 | 0 | broad | 471.124 | 439.835 | 6.82% | 6/6 |
| project | 100,000 | 2 | broad | 528.881 | 494.129 | 7.05% | 6/6 |
| project | 100,000 | 2 | sparse | 191.895 | 193.155 | -0.59% | 3/6 |
| project | 100,000 | 2 | none | 172.199 | 170.383 | 1.11% | 6/6 |
| project | 100,000 | 2 | blank | 0.003714 | 0.003736 | -0.54% | 2/6 |

All broad-match cases improved in every pair on this host, including the flat
controls. Metadata and Unicode broad matches also improved. Sparse, no-match,
and blank controls do not establish a useful speedup: their changed work is
small or absent, and their timing differences are mixed or tiny. Blank queries
take the unchanged early-return/cache-hit paths; percentages at this scale are
dominated by small absolute overheads and are not optimization claims.

Sources: [timing summary](../Benchmarks/SourceBrowserSearch/evidence/linux/timing/summary.json),
[all 216 measurements](../Benchmarks/SourceBrowserSearch/evidence/linux/timing/measurements.jsonl),
and [environment receipt](../Benchmarks/SourceBrowserSearch/evidence/linux/timing/environment.json).

### Separate Linux allocation measurements

The two-level, 100,000-media search removed **200,018 intercepted allocation
requests per operation**: 506,058 → 306,040 (**39.52%**). Requested bytes fell
213,850,487 → 184,239,975 (**13.85%**), a reduction of 29,610,512 requested
bytes per search. These are total request counts/traffic during the complete
operation, not retained or peak memory.

| Operation / query | Media rows | Ancestors | Requests, baseline → candidate | Requested bytes, baseline → candidate |
|---|---:|---:|---:|---:|
| search / broad | 100,000 | 0 | 500,058 → 300,040 | 197,794,839 → 183,999,975 |
| search / broad | 100,000 | 2 | 506,058 → 306,040 | 213,850,487 → 184,239,975 |
| search / broad | 100,000 | 8 | 524,058 → 324,040 | 274,698,647 → 184,959,975 |
| search / sparse | 100,000 | 2 | 308,039 → 306,029 | 15,809,823 → 15,616,295 |
| search / none | 100,000 | 2 | 306,004 → 306,004 | 12,240,252 → 12,240,252 |
| project / broad | 100,000 | 2 | 1,106,093 → 906,074.5 | 289,412,910 → 259,801,834 |

Search counts and requested bytes were identical between the two repetitions
of each variant in these cases. The projection measurements differ by one
request across observations, so their median counts can be fractional. The primary
two-level projection showed an **18.08%** paired request reduction and a
**10.23%** paired requested-byte reduction. Tiny fluctuations in empty or blank
projection controls are not allocation-saving claims.

Sources: [allocation summary](../Benchmarks/SourceBrowserSearch/evidence/linux/allocations/summary.json)
and [all 72 instrumented observations](../Benchmarks/SourceBrowserSearch/evidence/linux/allocations/measurements.jsonl).

The [exact Linux qualification archive](../Benchmarks/SourceBrowserSearch/evidence/linux/qualification.zip)
also retains command/build logs, calibration records, staged source files, and
runner snapshots. Its SHA-256 matches GitHub artifact `12220531524`:
`b4812096ba73ca4a9a690e244a25e7d4a848aad1915a4010518e6e2cabb81e00`.
The source files and allocation-meter C/header inputs are hashed in the build
receipts. The candidate Filter and benchmark harness match the published
qualification revision exactly.

## Evidence provenance and limits

The qualification source revision is
`6cd039e9a24310e4ab42e50298131d7dbfb56203`. GitHub Actions checks out the PR merge
revision, which is recorded separately by each run. Main changed the private
media-name recognition implementation after the pinned baseline, while leaving
the search and row declarations unchanged. Both compared builds receive the
same current helper. Recognition is performed only during fixture setup and is
outside the measured operations.

Initial exploratory and local Linux runs informed the choice of area. A
transient workspace reset removed their raw files before archival. They are
excluded from the numerical evidence in this report; the retained replacement
cohorts are the basis for its results. Superseded CI runs canceled by publication
of workflow/receipt fixes are likewise excluded.

This experiment establishes the measured Linux allocation reductions, checks
behavioral equivalence, and finds repeated favorable native timings for the
specified small-search and nested-projection workloads. Other native results
remain mixed. All workloads use constructed expanded rows. It does not measure physical typing, SwiftUI rendering, filesystem
I/O, source discovery, decoding, frame delivery, energy use, or whole-player
CPU. The effect on interactive latency depends on actual library shape, query
selectivity, task cancellation, and the other work in the source browser.
