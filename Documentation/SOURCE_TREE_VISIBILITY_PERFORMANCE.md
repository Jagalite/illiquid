# Source-tree reuse during visibility edits

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
production source APIs are unchanged. It measures complete projection calls after constructing
the fixture inputs. Visibility evaluation, path-set construction, and media
grouping remain within the measured call when the requested operation requires
them. Result verification is outside the timed interval.

The comparison includes visibility edits and controls for unchanged-input
search, rule preview, cold projection, and structural changes. Baseline and
candidate use the same compiler, fixture inputs, iteration counts, and shared
source declarations. Fresh processes alternate baseline/candidate order.

These are component measurements. They do not measure SwiftUI layout, displayed
response latency, playback CPU, energy, or native storage performance. The
existing complete macOS release test job supplies integration coverage; the
focused macOS job repeats the component tests and timing matrix.

## Qualification status and local results

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

The first native attempt passed both debug suites and compiled the baseline in
release mode, then failed during release test loading: the test helper invoked
the benchmark command-line entry point and it rejected the testing arguments.
No timing observations were collected. The
[failed artifact and receipt](PerformanceEvidence/SourceTreeVisibility/macos-attempt-1)
are retained. The package now keeps the production library and executable driver
in separate targets, removing the benchmark entry point from the test dependency
graph. It does not suppress argument errors or skip test discovery.

Native macOS component and application qualification is being rerun with that
packaging correction. The PR remains a draft until those results are reviewed.

Each time below is the median of six fresh-process average call durations.
The reduction is the median of the six paired reductions, so it need not equal
the ratio of the two displayed medians. All visibility-edit pairs favor the
candidate. Raw ranges and individual durations are retained alongside the
[reviewed summary](PerformanceEvidence/SourceTreeVisibility/linux/reviewed-summary.json).

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
same tree/visibility build counts and show small mixed differences, including
slower candidate samples. They do not establish a control-path speedup or
prove the absence of a small overhead. The incomplete 10,000-file sort cell
is omitted from this table and retained in `measurements.jsonl`.

The fixture is one wide folder with preloaded media recognition. The measurements
do not cover every real directory shape, simultaneous filesystem changes,
network shares, or complete on-screen latency. No whole-player CPU, frame-rate,
or energy improvement is claimed.

## Reproduction

See [`Benchmarks/SourceTreeVisibility`](../Benchmarks/SourceTreeVisibility) for
the runner, baseline receipt, source extraction boundaries, raw observations,
and measured results. The original Linux runner and retained baseline are
available at commit `daa5ea76d0bb570783cc91c521f34790ed8e1539`; the current
runner qualifies the baseline from the newer consolidation. The `source-tree-visibility` job in
`.github/workflows/non-decoding-performance.yml` retains its evidence as a
GitHub Actions artifact.
