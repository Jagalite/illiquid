# Source-tree reuse during visibility edits

The completed native macOS run measured 76.7–88.1% less background projection
time for visibility edits in the 10,000-file fixture. All 108 visibility-edit
pairs across the three fixture sizes favor tree reuse. The full timing matrix
completed; control results are mixed and retained alongside the gains below.

The completed macOS qualification shows a 76.7–88.1% median paired reduction
in projection time for visibility edits over 10,000 files. All eighteen
visibility-edit cells favor the candidate in every pair. All twelve control
cells were also collected; their mixed results do not establish a general
control-path improvement or the absence of overhead. The native component
tests passed in debug and release. Results and source provenance are retained
in the [native qualification receipt](PerformanceEvidence/SourceTreeVisibility/macos/qualification.json)
and [complete native artifact](PerformanceEvidence/SourceTreeVisibility/macos/qualification.zip).

## Problem and scope

The media browser refreshes its background projection when a visibility setting
changes. At the research baseline, `SourceBrowserFilter.project(input:...)`
compares the entire `SourceTreeProjectionInput` with its cached input. The
synthesized comparison includes hidden paths, always-shown paths, regex rules,
rule colors, and the Show Hidden setting. Changing any of them rebuilds the raw
rows, including sorting and recursive row construction, before applying the new
visibility configuration.

Among visibility settings, raw row contents depend only on
`visibility.viewMode`. That mode determines
whether to traverse the expanded tree or a recursive file list and whether to
recognize media names. `makeFlatFileRows()` also creates a visibility matcher,
but calls only its relative-path method, whose result depends on the roots.
Matcher initialization still compiles rules; that work does not change the raw
rows produced here.
The other visibility settings are applied in the subsequent visibility pass.

The initial Linux investigation used consolidated `main` at
`68274d1b09dcc866296321a5a8858efc297c4f19`. Before native qualification, `main`
advanced to `33fff16155c3472960f88e04c72dfdfdefd56dcf`. The native benchmark
baseline was refreshed to that revision so its shared media-recognition and
sidecar dependencies match the current project. The production change is the
same in both cohorts. Results identify their baseline separately.

This change addresses visibility-setting edits after the tree exists. The
previously implemented empty-search projection cache remains in use.

## Change

`SourceTreeProjectionInput.hasSameTree(as:)` first compares the exact view mode.
It then substitutes the current visibility configuration into a local value
copy of the previous input and uses the existing synthesized equality. All
other fields still participate, including fields added to this value type in
the future. The full `Equatable` behavior remains unchanged.

The filter uses this narrower comparison solely for its raw-tree cache. Its
visibility cache still compares the full current configuration, roots, rows,
and rule-preview state. Every visibility change therefore recomputes hidden
annotations, hidden counts, regex counts, and the visible projection. Search
and media grouping continue to use those updated rows.

The filter also refreshes its retained input on a tree cache hit. This releases
removed visibility settings instead of retaining the configuration from the
first tree build.

The following inputs continue to rebuild the tree:

- Source items and roots.
- Directory contents and directory errors.
- Recursive media entries.
- Expanded folders and sort configuration.
- Media-presence results.
- The exact view mode, including Files Only versus Media.

## Correctness qualification

`SourceTreeVisibilityCacheTests` compares an actor that reuses its cache with a
fresh actor across sixteen successive visibility configurations in each of
the four view modes. Each configuration is exercised with rule preview on and
off and three search queries. Comparisons include complete ordered rows and
their annotations, hidden counts, regex counts, thumbnail candidates, and the
media-path set. Previously returned projections are checked after subsequent
edits.

A separate test checks that these edits build the tree once while rebuilding
visibility for every changed configuration. This assertion is expected to
fail on the baseline; the semantic comparison tests are expected to pass on
both variants. Structural replacement cases check actual changed output,
equality with a fresh projection, and a second tree build. A pre-cancelled
request checks that the preceding tree remains available and that a subsequent
accepted replacement works.

## Measurement scope

The benchmark runs the actual background actor and row-building sources in an
isolated Swift library, with a separate executable driver. Both variants enable
testability on that library so the driver can access internal declarations;
production source APIs are unchanged. It measures complete projection calls
after constructing the fixture inputs. Visibility evaluation, path-set
construction, and media grouping remain within the measured call when the
requested operation requires them. Result verification is outside the timed
interval.

The comparison includes visibility edits and controls for unchanged-input
search, rule preview, cold projection, and structural changes. Baseline and
candidate use the same compiler, fixture inputs, iteration counts, and shared
source declarations. Fresh processes alternate baseline/candidate order.

These are component measurements. They do not measure SwiftUI layout, displayed
response latency, playback CPU, energy, or native storage performance. The
fixture is one wide folder with preloaded media recognition. It does not cover
every real directory shape, simultaneous filesystem changes, or network shares.
Cold projection means a fresh actor after process and fixture initialization;
it does not measure process startup or a cold filesystem cache. Full application
integration is tracked separately below.

Each displayed duration is the median of six fresh-process mean call durations.
For a pair `p`, let `B_p` and `C_p` be the arithmetic means of the individual
baseline and candidate call durations in that process. The two time columns
are `median(B_p)` and `median(C_p)`, converted from nanoseconds to milliseconds.
The reduction column is `median(100 * (1 - C_p / B_p))` over the six matched
pairs. Separate medians can select values from different pairs, so the paired
reduction can differ in magnitude or sign from a ratio of the displayed time
columns. Negative reductions mean slower candidate samples.

The native run uses 12, 6, and 2 timed calls per process for 100, 1,000, and
10,000 files respectively. The faster `same_input_search` and `preview_only`
controls use 100, 24, and 4 calls respectively. Every pair has equal call counts
for both variants. Fixture creation, warmup, output checksums, and cache-count
diagnostics are outside the timers. The output receipts cover all row fields,
visibility annotations, thumbnail candidates, media paths, and counts; full
projection equality is checked independently by the regression tests.

## Native macOS qualification and results

The [completed native run](https://github.com/Jagalite/illiquid/actions/runs/39322896553)
collected all 30 workload/size cells: eighteen visibility-edit cells and twelve
controls, each with six pairs. This gives 360 timed process observations
covering 4,992 projection calls, with another 60 untimed diagnostic observations. Baseline and candidate output
receipts match within every paired observation. The tables below were
recomputed from the individual durations in `measurements.jsonl` and agree
with the retained `summary.json`.

| Native cohort field | Value |
| --- | --- |
| Started | 2026-10-19 at 21:07:43 UTC |
| Host | GitHub-hosted macOS 26.6.2, arm64 |
| Compiler | Apple Swift 6.3.3 (`swiftlang-6.3.3.1.3`), Xcode 26.6 |
| Target | `arm64-apple-macosx26.0` |
| Baseline | `33fff16155c3472960f88e04c72dfdfdefd56dcf` |
| Measured PR head | `833c79a2d2e2ca675990c1009f0f7891f29c3bb0` |
| Tested merge commit | `d851a023d30a178bec587458a44415ba68ffbc88` |
| Native artifact | `source-tree-visibility`, ID `12222481457` |

The test logs confirm 15 baseline and 16 candidate tests across the three
suites in both debug and release. Only the baseline omits
`reuseTreeAcrossVisibilityChanges`, which asserts the new cache behavior;
the candidate runs it in all four view modes. Both variants pass the semantic
and structural regression tests. The separate documented component-regressions
job also passed.

The [native application release job](https://github.com/Jagalite/illiquid/actions/runs/39322896654/job/118301557712)
built the complete application graph and passed the configured suite: 68
XCTest tests with zero failures, plus a successful Swift Testing summary of
1,392 tests in 193 suites. All four new cache test methods passed, including
all four modes in each parameterized test. Existing opt-in fixture and
performance cases remain skipped as configured. The focused core, native
presentation, and geometry jobs also passed on the same tested merge.

The follow-up that retains these results changes only documentation and
evidence. Production sources, tests, benchmark driver, baseline snapshots,
package configuration, and workflows remain identical to the measured head.
The [qualification receipt](PerformanceEvidence/SourceTreeVisibility/macos/qualification.json)
records the integration jobs, selected native test log lines, and that source
comparison.

### Visibility edits on macOS

| Files | Operation | Baseline ms/call | Candidate ms/call | Paired median reduction |
| ---: | --- | ---: | ---: | ---: |
| 100 | `tree_rules` | 5.904 | 0.899 | 84.7% |
| 100 | `tree_show_hidden` | 5.070 | 0.987 | 80.5% |
| 100 | `tree_manual_hide` | 4.962 | 0.845 | 82.7% |
| 100 | `tree_always_show` | 5.960 | 1.136 | 80.8% |
| 100 | `files_rules` | 6.740 | 1.658 | 76.1% |
| 100 | `media_rules` | 8.308 | 2.377 | 75.5% |
| 1,000 | `tree_rules` | 64.042 | 8.015 | 86.5% |
| 1,000 | `tree_show_hidden` | 51.419 | 8.062 | 85.0% |
| 1,000 | `tree_manual_hide` | 42.950 | 5.718 | 87.1% |
| 1,000 | `tree_always_show` | 45.682 | 7.231 | 84.0% |
| 1,000 | `files_rules` | 57.661 | 8.227 | 85.5% |
| 1,000 | `media_rules` | 127.457 | 24.172 | 77.6% |
| 10,000 | `tree_rules` | 434.629 | 56.890 | 87.1% |
| 10,000 | `tree_show_hidden` | 477.373 | 65.021 | 85.9% |
| 10,000 | `tree_manual_hide` | 481.431 | 59.345 | 88.1% |
| 10,000 | `tree_always_show` | 489.505 | 70.424 | 85.7% |
| 10,000 | `files_rules` | 602.948 | 83.290 | 86.2% |
| 10,000 | `media_rules` | 638.123 | 148.173 | 76.7% |

All 108 visibility-edit pairs favor the candidate. At 10,000 files, the median
paired reductions range from 76.7% for the Media view to 88.1% for manual hiding.
The remaining work includes visibility evaluation and output construction;
Media view also retains the grouping work needed for the projection.

Separate untimed diagnostics show three raw-tree builds for the baseline
(one initial build plus two changed settings) versus one for the candidate
in all eighteen visibility cells. Both perform three visibility builds and
return matching receipts. The avoided work is row construction and sorting;
the new visibility configuration is still evaluated on every change.

### macOS controls

| Files | Operation | Baseline ms/call | Candidate ms/call | Paired median reduction |
| ---: | --- | ---: | ---: | ---: |
| 100 | `same_input_search` | 0.396 | 0.354 | 1.8% |
| 100 | `preview_only` | 0.929 | 0.910 | -1.1% |
| 100 | `cold_tree` | 3.853 | 4.376 | -7.7% |
| 100 | `changed_sort` | 5.733 | 5.141 | 9.2% |
| 1,000 | `same_input_search` | 4.486 | 3.486 | 22.2% |
| 1,000 | `preview_only` | 10.375 | 11.278 | 0.7% |
| 1,000 | `cold_tree` | 46.412 | 43.825 | 2.1% |
| 1,000 | `changed_sort` | 53.671 | 50.434 | -6.2% |
| 10,000 | `same_input_search` | 25.613 | 25.456 | 0.4% |
| 10,000 | `preview_only` | 76.462 | 74.030 | -0.4% |
| 10,000 | `cold_tree` | 409.796 | 414.727 | -0.8% |
| 10,000 | `changed_sort` | 424.461 | 407.663 | 4.4% |

The controls retain the same raw-tree and visibility build counts in both
variants. Their paired median reductions range from -7.7% to 22.2%, and several
cells have substantial variation between pairs. For example, the 1,000-file
search control has a 22.2% median paired reduction, while its six individual
paired reductions range from -14.9% to 61.9%. Five of those six search pairs
favor the candidate. Both variants build the tree and visibility once in that
control, so avoided tree builds cannot explain its recorded reduction.
One baseline search process (pair 4) averaged 13.929 ms and included a
124.556 ms call. The cause of that extreme is unconfirmed, and those samples
remain included in the results.
The 100-file cold control has a -7.7% median paired reduction, and the
1,000-file sort control has -6.2%.
These observations do not establish a general control-path speedup or prove
that the changed cache comparison has no overhead. Six pairs on one hosted
runner do not quantify all sources of timing variation.

The native and historical Linux cohorts use different platforms, compiler
versions, shared-dependency baselines, and benchmark package layouts. Native
measurements use the production library with explicit testability and a
separate driver; the original Linux driver shared the executable module with
the production sources. Their absolute timings are separate observations,
not a controlled comparison between operating systems or compiler versions.

## Historical Linux qualification and results

The Linux component tests passed for both source variants in debug and release:
15 baseline test methods and 16 candidate methods across all three suites.
The extra candidate method proves tree reuse and deliberately fails on the
baseline in all four view modes. Semantic comparison tests pass on both.

The timing run started on 2026-10-17 at 20:23 UTC, using Swift 6.3.2 on an
x86_64 Linux host reporting an AMD EPYC 9V74. It completed 29 of the 30
six-pair workload/size cells, including every visibility-edit cell. The final
10,000-file sort control stopped after one complete pair when the candidate
process exited with SIGILL. Its unsymbolized crash dump contains a
`/proc/.../stat` path in a register. This resembles an earlier unmodified Swift
driver failure on this host, but the final crash cause is unconfirmed. This is
an incomplete Linux run, not a passing complete matrix.
The failed command and the partial cell remain in the raw evidence. Only
complete six-pair cells appear below.

All historical Linux visibility-edit pairs favor the candidate. Raw ranges and
individual durations are retained alongside the
[reviewed Linux summary](PerformanceEvidence/SourceTreeVisibility/linux/reviewed-summary.json).

### Visibility edits on Linux

| Files | Operation | Baseline ms/call | Candidate ms/call | Paired median reduction |
| ---: | --- | ---: | ---: | ---: |
| 100 | `tree_rules` | 5.216 | 0.685 | 86.8% |
| 100 | `tree_show_hidden` | 5.228 | 0.913 | 84.7% |
| 100 | `tree_manual_hide` | 5.016 | 0.628 | 88.4% |
| 100 | `tree_always_show` | 5.287 | 0.894 | 84.0% |
| 100 | `files_rules` | 7.701 | 0.938 | 87.6% |
| 100 | `media_rules` | 7.500 | 1.675 | 78.3% |
| 1,000 | `tree_rules` | 68.345 | 5.720 | 91.6% |
| 1,000 | `tree_show_hidden` | 67.565 | 5.864 | 91.4% |
| 1,000 | `tree_manual_hide` | 72.948 | 5.976 | 91.8% |
| 1,000 | `tree_always_show` | 81.534 | 6.678 | 91.7% |
| 1,000 | `files_rules` | 107.312 | 9.575 | 91.0% |
| 1,000 | `media_rules` | 92.946 | 15.251 | 84.1% |
| 10,000 | `tree_rules` | 725.818 | 57.267 | 92.2% |
| 10,000 | `tree_show_hidden` | 712.510 | 62.152 | 91.4% |
| 10,000 | `tree_manual_hide` | 679.585 | 54.543 | 92.1% |
| 10,000 | `tree_always_show` | 742.124 | 71.735 | 90.3% |
| 10,000 | `files_rules` | 873.055 | 80.772 | 90.5% |
| 10,000 | `media_rules` | 922.834 | 162.769 | 82.9% |

Separate untimed diagnostics show three raw-tree builds for the baseline
(one warmup plus two changed settings) versus one for the candidate. Both
perform three visibility builds and return matching result receipts. The
saved work is row construction and sorting; visibility evaluation still runs.

### Linux controls

| Files | Operation | Baseline ms/call | Candidate ms/call | Paired median reduction |
| ---: | --- | ---: | ---: | ---: |
| 100 | `same_input_search` | 0.394 | 0.396 | -0.6% |
| 100 | `preview_only` | 0.858 | 0.934 | 0.8% |
| 100 | `cold_tree` | 5.883 | 6.235 | -8.3% |
| 100 | `changed_sort` | 6.082 | 5.591 | 2.1% |
| 1,000 | `same_input_search` | 2.676 | 2.681 | -2.6% |
| 1,000 | `preview_only` | 7.313 | 7.250 | -2.1% |
| 1,000 | `cold_tree` | 66.041 | 66.316 | -1.8% |
| 1,000 | `changed_sort` | 72.883 | 68.781 | 5.6% |
| 10,000 | `same_input_search` | 26.802 | 28.579 | -3.1% |
| 10,000 | `preview_only` | 73.438 | 73.793 | -1.8% |
| 10,000 | `cold_tree` | 648.402 | 655.572 | -2.9% |

Negative reductions mean slower candidate samples. These controls retain the
same tree/visibility build counts and show mixed differences, including
slower candidate samples. They do not establish a control-path speedup or
prove the absence of overhead. The incomplete 10,000-file sort cell
is omitted from this table and retained in `measurements.jsonl`.

## First native qualification attempt

The first native attempt passed the component tests for both variants in debug
and compiled the baseline in release mode, then failed during release test
loading: the test helper invoked the benchmark command-line entry point and it
rejected the testing arguments.
No timing observations were collected. The
[failed artifact and receipt](PerformanceEvidence/SourceTreeVisibility/macos-attempt-1)
are retained. The package now keeps the production library and executable driver
in separate targets, removing the benchmark entry point from the test dependency
graph. It does not suppress argument errors or skip test discovery.

The corrected package subsequently completed the native qualification reported
above. The first attempt remains part of the evidence history and contributes
no performance samples to the completed native cohort.

## Reproduction

See [`Benchmarks/SourceTreeVisibility`](../Benchmarks/SourceTreeVisibility) for
the runner, baseline receipt, source extraction boundaries, and workload
configuration. The [retained native artifact](PerformanceEvidence/SourceTreeVisibility/macos/qualification.zip)
contains the raw measurements and diagnostics, summary, environment, test logs,
command records, source manifests, and exact staged sources. The accompanying
[qualification receipt](PerformanceEvidence/SourceTreeVisibility/macos/qualification.json)
records artifact identity and provenance.

The original Linux runner and retained baseline are available at commit
`daa5ea76d0bb570783cc91c521f34790ed8e1539`; the current runner qualifies the
baseline from the newer consolidation. Historical Linux observations remain
in [their original evidence directory](PerformanceEvidence/SourceTreeVisibility/linux),
including the failed command and incomplete final control. The
`source-tree-visibility` job in `.github/workflows/non-decoding-performance.yml`
retains each run's evidence as a GitHub Actions artifact.
