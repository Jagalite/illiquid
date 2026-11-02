# Manual source visibility rebuild performance

## Finding

The optimization improved warm source-browser visibility rebuilds on both
native macOS and portable Linux cohorts.

On macOS 26.6.2 / Apple M1 (Virtual), the 10,000-entry manual-hide workload
changed from a 67.252 ms baseline median to 52.239 ms candidate median.
The median paired reduction is **21.04%**, and all eight pairs improve.
The ASCII-path version shows a **10.12%** paired reduction with seven of
eight favorable pairs. Native control variation is retained and discussed
below.

Linux independently corroborates the targeted effect: the corresponding
manual-hide and ASCII cases improve by **30.84%** and **19.19%**.
These are component measurements on the specified hosts, not whole-player
UI or playback measurements.

## Production change

`SourceVisibilityMatcher` used to derive a relative path and construct an
`NSRange` for every evaluation, even when no enabled regex successfully
compiled. The private evaluation helper now accepts its candidate as an
`@autoclosure`. If the compiled-rule array is empty, it returns the same
manual-only visibility result immediately. If any compiled rule exists, it
evaluates the candidate once and runs the existing regex logic.

This avoids unnecessary path and UTF-16 range preparation for manual hidden
paths and always-show settings. It also covers disabled or invalid regexes when
they leave no compiled rules. Manual hide continues to take precedence over an
always-show entry for the same path. Ancestor traversal, root caching, match
ordering, visibility annotations, and the projection cache are unchanged.

The production diff is 10 additions and one deletion in
`Sources/IlliquidApp/UI/SourcesSidebar.swift`; the remaining changes are tests,
benchmark infrastructure, and this research record.

## Qualification

| Qualification | Status | Evidence |
| --- | --- | --- |
| Native component tests and paired benchmark | Passed | [Run 40636025973, component job](https://github.com/Jagalite/illiquid/actions/runs/40636025973/job/122643076850) |
| Portable Linux tests and paired benchmark | Passed | [Run 40639121107](https://github.com/Jagalite/illiquid/actions/runs/40639121107) |
| Full native app integration with pinned SDK | Queued at report preparation | [Integration job 122658470066](https://github.com/Jagalite/illiquid/actions/runs/40636025973/job/122658470066) |

The native cohort measured `c0a49f6348d1c7303a142c398b34136fc9f8ed64`;
the portable cohort measured `d9979d902ed4b89e3eb86a1ef9107a18698f0e7c`.
Their original production sources, harness, and regression tests are identical.
The later head adds the portable runner and workflow. Subsequent evidence and
documentation commits do not alter the measured production code.

Both cohorts used clean working trees. The native runner stages exact
production declarations without substitutions. Linux applies three guarded,
symmetric compatibility adaptations: Darwin to Glibc in the sidecar reader,
a FoundationXML import in the NFO parser, and an explicit directory hint in one
existing sidecar test fixture. Their original and compiled hashes are retained.

The component results do not imply that the separately queued full-app
integration job has passed. Consult that job for its eventual status.

## Method

- Pinned baseline: `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`.
- Measured candidate: native `c0a49f6348d1c7303a142c398b34136fc9f8ed64`; portable `d9979d902ed4b89e3eb86a1ef9107a18698f0e7c`.
- The component package contains actual production declarations extracted using
  the repository's existing guarded source-tree snapshot helper.
- Every supporting production source must be byte-identical between variants.
  The only permitted focal difference is inside `SourceVisibilityMatcher`.
- Both variants use the same harness and the same six test suites, run in debug
  and release. Timed binaries use release optimization.
- Each duration surrounds one awaited production
  `SourceBrowserFilter.project(input:revealsRulePreview:query:)` call.
- The raw tree is already warm. Settings or preview state alternate to force
  visibility to rebuild on every measured call. Cache counters are read only
  after the timed batch and must report one tree build and exactly one
  visibility build for each warmup and measured projection.
- Fixtures contain 100, 1,000, or 10,000 synthetic media entries under one lexical
  root, with flat or two-level nested folders. Media recognition is populated
  before timing. No filesystem data is read during the measurement.
- Fixture construction, compilation, process startup, warmups, receipt hashing,
  UI rendering, and playback are outside the timer.
- Each cell uses eight fresh-process pairs in balanced AB/BA order. The faster
  pilot chooses an identical even iteration count for both variants toward
  80 ms of measured work, capped at 1,024 calls. This is a target, not a
  guaranteed duration.
- A sample is a process mean. Reported speedup is the median of the eight paired
  baseline/candidate ratios. The reduction is `100 * (1 - 1 / speedup)`.
  Absolute times are medians of the process means and need not have exactly
  the same ratio as the paired statistic.
- Timings are observations; no performance threshold makes CI pass or fail.

Actual sample durations and undershoots of the calibration target are reported separately for each cohort below.

## Results

### Native macOS results

Host: macOS 26.6.2 (build 25G83), arm64, Apple M1 (Virtual),
Apple Swift 6.3.3 (`swiftlang-6.3.3.1.3`).
No source adaptations were applied.

| Workload, 10,000 media entries | Baseline ms | Candidate ms | Paired reduction | Winning pairs |
| --- | ---: | ---: | ---: | ---: |
| Manual hide, Unicode root | 67.252 | 52.239 | 21.04% | 8/8 |
| Manual hide, ASCII root | 41.337 | 37.469 | 10.12% | 7/8 |
| Manual-hide preview | 68.706 | 58.626 | 16.70% | 8/8 |
| Always-show paths | 69.516 | 52.305 | 24.79% | 8/8 |
| Manual hide + disabled regex | 72.215 | 57.884 | 19.25% | 8/8 |
| Invalid-only regex (defensive) | 71.540 | 58.007 | 20.97% | 8/8 |
| Nested manual tree | 74.695 | 58.216 | 21.15% | 8/8 |
| Nested manual Files view | 194.908 | 159.725 | 17.90% | 8/8 |
| Nested manual Media view | 247.148 | 215.574 | 12.78% | 8/8 |
| Default control | 51.665 | 54.035 | 0.97% | 4/8 |
| Disabled-only control | 55.198 | 54.702 | 4.47% | 6/8 |
| Active-regex tree control | 82.399 | 81.025 | 7.01% | 5/8 |
| Active-regex nested Files control | 251.808 | 254.180 | 1.99% | 5/8 |

All 27 workload cells that exercise the fast path have positive median
reductions, ranging from 10.12% to 26.28%. Twenty-four improve in all eight
pairs. The exceptions are ASCII at 1,000 entries (6/8), ASCII at 10,000 (7/8),
and invalid-only regexes at 1,000 (7/8). The invalid-rule fixture exercises a
defensive matcher path; it is not a claim about a typical normalized UI
configuration.

The main 10,000-entry manual case has a median paired speedup of 1.266×,
with individual pair ratios from 1.133× to 1.667×. Its benefit is also present
at 100 and 1,000 entries.

Native controls are visibly noisy. Their median paired reductions span
−4.42% to +7.01%; every control cell includes individual ratios on both
sides of 1.0. The 10,000-entry active-regex control's apparent +7.01%
improvement has ratios from 0.817× to 1.472× and only five favorable pairs.
It is a control observation, not evidence of an active-regex speedup or a
tight bound excluding small regressions on other workloads.

The 624 timed processes contain 28,256 timed projections. Accumulated measured
time per process ranged from 69.078 to 672.223 ms (median 102.985 ms).
64 processes fell below the 80 ms calibration target; none reached the
1,024-iteration cap.

#### Complete native matrix

| Workload | Media entries | Baseline ms | Candidate ms | Paired reduction | Winning pairs | Paired speedup range |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| Manual hide, Unicode root | 100 | 0.674 | 0.547 | 18.71% | 8/8 | 1.007–1.252× |
| Manual hide, Unicode root | 1,000 | 6.314 | 5.115 | 19.65% | 8/8 | 1.217–1.287× |
| Manual hide, Unicode root | 10,000 | 67.252 | 52.239 | 21.04% | 8/8 | 1.133–1.667× |
| Manual hide, ASCII root | 100 | 0.444 | 0.395 | 10.64% | 8/8 | 1.053–1.166× |
| Manual hide, ASCII root | 1,000 | 4.272 | 3.701 | 13.29% | 6/8 | 0.226–1.877× |
| Manual hide, ASCII root | 10,000 | 41.337 | 37.469 | 10.12% | 7/8 | 0.828–1.144× |
| Manual-hide preview | 100 | 0.774 | 0.600 | 23.34% | 8/8 | 1.029–1.760× |
| Manual-hide preview | 1,000 | 6.912 | 5.549 | 20.39% | 8/8 | 1.091–1.430× |
| Manual-hide preview | 10,000 | 68.706 | 58.626 | 16.70% | 8/8 | 1.109–1.325× |
| Always-show paths | 100 | 0.750 | 0.565 | 24.66% | 8/8 | 1.277–1.765× |
| Always-show paths | 1,000 | 7.110 | 5.431 | 23.43% | 8/8 | 1.193–1.342× |
| Always-show paths | 10,000 | 69.516 | 52.305 | 24.79% | 8/8 | 1.289–1.451× |
| Manual hide + disabled regex | 100 | 0.708 | 0.564 | 21.55% | 8/8 | 1.223–1.346× |
| Manual hide + disabled regex | 1,000 | 6.689 | 5.544 | 17.51% | 8/8 | 1.166–1.258× |
| Manual hide + disabled regex | 10,000 | 72.215 | 57.884 | 19.25% | 8/8 | 1.109–1.956× |
| Invalid-only regex (defensive) | 100 | 0.913 | 0.698 | 26.28% | 8/8 | 1.054–1.647× |
| Invalid-only regex (defensive) | 1,000 | 7.099 | 5.758 | 18.62% | 7/8 | 0.984–1.287× |
| Invalid-only regex (defensive) | 10,000 | 71.540 | 58.007 | 20.97% | 8/8 | 1.118–1.369× |
| Nested manual tree | 100 | 0.618 | 0.481 | 22.97% | 8/8 | 1.126–1.548× |
| Nested manual tree | 1,000 | 6.531 | 5.339 | 18.10% | 8/8 | 1.165–1.270× |
| Nested manual tree | 10,000 | 74.695 | 58.216 | 21.15% | 8/8 | 1.149–1.351× |
| Nested manual Files view | 100 | 1.667 | 1.322 | 20.47% | 8/8 | 1.245–1.304× |
| Nested manual Files view | 1,000 | 18.385 | 15.309 | 17.81% | 8/8 | 1.148–1.264× |
| Nested manual Files view | 10,000 | 194.908 | 159.725 | 17.90% | 8/8 | 1.122–1.271× |
| Nested manual Media view | 100 | 1.959 | 1.565 | 19.64% | 8/8 | 1.180–1.459× |
| Nested manual Media view | 1,000 | 22.903 | 19.765 | 12.94% | 8/8 | 1.102–1.200× |
| Nested manual Media view | 10,000 | 247.148 | 215.574 | 12.78% | 8/8 | 1.081–1.196× |
| Default control | 100 | 0.541 | 0.540 | -0.15% | 4/8 | 0.869–1.058× |
| Default control | 1,000 | 5.103 | 5.119 | 0.35% | 4/8 | 0.925–1.215× |
| Default control | 10,000 | 51.665 | 54.035 | 0.97% | 4/8 | 0.876–1.112× |
| Disabled-only control | 100 | 0.651 | 0.661 | -1.71% | 3/8 | 0.920–1.114× |
| Disabled-only control | 1,000 | 6.136 | 6.571 | -4.00% | 1/8 | 0.804–1.031× |
| Disabled-only control | 10,000 | 55.198 | 54.702 | 4.47% | 6/8 | 0.919–1.654× |
| Active-regex tree control | 100 | 0.873 | 0.881 | -4.42% | 2/8 | 0.842–1.084× |
| Active-regex tree control | 1,000 | 7.987 | 7.916 | 0.67% | 5/8 | 0.985–1.288× |
| Active-regex tree control | 10,000 | 82.399 | 81.025 | 7.01% | 5/8 | 0.817–1.472× |
| Active-regex nested Files control | 100 | 2.561 | 2.614 | -2.08% | 2/8 | 0.941–1.102× |
| Active-regex nested Files control | 1,000 | 25.115 | 25.345 | -1.46% | 3/8 | 0.649–1.084× |
| Active-regex nested Files control | 10,000 | 251.808 | 254.180 | 1.99% | 5/8 | 0.917–1.229× |

### Portable Linux results

Host: Ubuntu 24.04.5, x86_64, Intel Xeon Platinum 8370C at 2.80 GHz,
four CPUs in the process affinity set, glibc 2.39, Swift 6.4
(`swift-6.4-RELEASE`). These timings are independent of the native cohort.

| Workload, 10,000 media entries | Baseline ms | Candidate ms | Paired reduction |
| --- | ---: | ---: | ---: |
| Manual hide, Unicode root | 56.599 | 39.169 | 30.84% |
| Manual hide, ASCII root | 29.440 | 23.797 | 19.19% |
| Manual-hide preview | 58.268 | 40.991 | 29.65% |
| Always-show paths | 56.172 | 34.095 | 39.26% |
| Manual hide + disabled regex | 56.498 | 38.811 | 31.36% |
| Invalid-only regex (defensive) | 50.911 | 34.406 | 32.78% |
| Nested manual tree | 67.649 | 49.227 | 27.21% |
| Nested manual Files view | 159.317 | 111.643 | 29.92% |
| Nested manual Media view | 203.406 | 154.161 | 24.26% |
| Default control | 33.783 | 33.570 | 0.68% |
| Disabled-only control | 33.430 | 33.837 | -0.44% |
| Active-regex tree control | 76.776 | 76.571 | 0.07% |
| Active-regex nested Files control | 220.451 | 218.421 | 0.85% |

All 27 workload cells that exercise the fast path improved in all eight pairs.
Their median paired reductions ranged from 18.65% to 39.40%. The 10,000-entry
manual Unicode-root case had paired speedups from 1.427× to 1.474×, with a
median of 1.446×. The ASCII-root case also improved, by 19.19%.

Across all 12 control cells, median paired changes ranged from −1.16% to
+1.46%, with individual paired ratios on both sides of 1.0 in every control
cell. No material control regression was observed in this cohort. This is
an observation, not a guarantee for other hosts.

The 624 timed processes contain 39,776 timed projections. Accumulated measured
time per process ranged from 74.790 to 448.732 ms (median 104.628 ms).
50 processes fell below the 80 ms calibration target; none reached the
1,024-iteration cap.

#### Complete Linux matrix

| Workload | Media entries | Baseline ms | Candidate ms | Paired reduction | Paired speedup range |
| --- | ---: | ---: | ---: | ---: | --- |
| Manual hide, Unicode root | 100 | 0.581 | 0.401 | 31.17% | 1.425–1.492× |
| Manual hide, Unicode root | 1,000 | 5.690 | 3.885 | 31.71% | 1.400–1.484× |
| Manual hide, Unicode root | 10,000 | 56.599 | 39.169 | 30.84% | 1.427–1.474× |
| Manual hide, ASCII root | 100 | 0.314 | 0.256 | 18.65% | 1.180–1.257× |
| Manual hide, ASCII root | 1,000 | 2.918 | 2.348 | 19.43% | 1.162–1.270× |
| Manual hide, ASCII root | 10,000 | 29.440 | 23.797 | 19.19% | 1.213–1.252× |
| Manual-hide preview | 100 | 0.616 | 0.434 | 29.12% | 1.380–1.456× |
| Manual-hide preview | 1,000 | 5.669 | 3.905 | 31.29% | 1.425–1.479× |
| Manual-hide preview | 10,000 | 58.268 | 40.991 | 29.65% | 1.388–1.489× |
| Always-show paths | 100 | 0.630 | 0.408 | 35.66% | 1.500–1.590× |
| Always-show paths | 1,000 | 5.634 | 3.409 | 39.40% | 1.623–1.694× |
| Always-show paths | 10,000 | 56.172 | 34.095 | 39.26% | 1.614–1.683× |
| Manual hide + disabled regex | 100 | 0.575 | 0.401 | 29.87% | 1.389–1.475× |
| Manual hide + disabled regex | 1,000 | 5.655 | 3.868 | 31.27% | 1.413–1.488× |
| Manual hide + disabled regex | 10,000 | 56.498 | 38.811 | 31.36% | 1.409–1.488× |
| Invalid-only regex (defensive) | 100 | 0.585 | 0.418 | 28.47% | 1.362–1.469× |
| Invalid-only regex (defensive) | 1,000 | 5.041 | 3.455 | 31.35% | 1.443–1.487× |
| Invalid-only regex (defensive) | 10,000 | 50.911 | 34.406 | 32.78% | 1.449–1.510× |
| Nested manual tree | 100 | 0.568 | 0.383 | 33.12% | 1.456–1.528× |
| Nested manual tree | 1,000 | 6.238 | 4.315 | 30.52% | 1.398–1.481× |
| Nested manual tree | 10,000 | 67.649 | 49.227 | 27.21% | 1.349–1.417× |
| Nested manual Files view | 100 | 1.338 | 0.909 | 32.62% | 1.421–1.511× |
| Nested manual Files view | 1,000 | 15.353 | 10.675 | 30.19% | 1.410–1.475× |
| Nested manual Files view | 10,000 | 159.317 | 111.643 | 29.92% | 1.405–1.455× |
| Nested manual Media view | 100 | 1.559 | 1.155 | 27.00% | 1.327–1.383× |
| Nested manual Media view | 1,000 | 18.799 | 13.968 | 25.93% | 1.319–1.392× |
| Nested manual Media view | 10,000 | 203.406 | 154.161 | 24.26% | 1.272–1.357× |
| Default control | 100 | 0.401 | 0.406 | 0.67% | 0.959–1.026× |
| Default control | 1,000 | 3.425 | 3.423 | 0.43% | 0.984–1.025× |
| Default control | 10,000 | 33.783 | 33.570 | 0.68% | 0.978–1.031× |
| Disabled-only control | 100 | 0.401 | 0.406 | -0.69% | 0.958–1.026× |
| Disabled-only control | 1,000 | 3.402 | 3.481 | -1.16% | 0.954–1.022× |
| Disabled-only control | 10,000 | 33.430 | 33.837 | -0.44% | 0.950–1.019× |
| Active-regex tree control | 100 | 0.800 | 0.796 | 0.76% | 0.985–1.047× |
| Active-regex tree control | 1,000 | 7.461 | 7.477 | 1.11% | 0.967–1.027× |
| Active-regex tree control | 10,000 | 76.776 | 76.571 | 0.07% | 0.992–1.021× |
| Active-regex nested Files control | 100 | 2.223 | 2.215 | 1.46% | 0.974–1.027× |
| Active-regex nested Files control | 1,000 | 21.536 | 21.618 | -0.18% | 0.969–1.010× |
| Active-regex nested Files control | 10,000 | 220.451 | 218.421 | 0.85% | 0.979–1.029× |


The default and disabled-only controls already bypass per-row visibility
matching. Active-regex controls exercise the unchanged regex path. Keep the two
platforms' observations separate: the native control spread is considerably
wider than the portable control spread.

## Correctness

Each platform passed the same 39 test functions against baseline and candidate
in both debug and release: eight successful test runs across the two platforms.
The new matcher suite covers absent, disabled, and invalid rules; manual-hide
precedence over always-show; hidden roots and ancestors; overlapping Unicode
roots; active-regex order; preview annotations; and the Tree, Files, and Media
projections.

Each cohort also passed 78 differential diagnostic observations across all
13 cases at 1, 31, and 257 media entries. Timed receipts match across variants
and repetitions for all 1,248 measured processes. Their 68,032 individual
timed projections all have valid durations, and each process reports the
required raw-tree and visibility-build counts.

Receipts cover ordered row fields and metadata, visibility annotations,
hidden and regex counts, thumbnail ordering, and media-path membership.
Flat-workload row and hidden counts were also checked against the requested
fixture sizes. Source receipts match the pinned baseline Git tree; only the
focal matcher snapshot differs, and the candidate's source hash matches the
committed production change.

An initial full-app native attempt compiled successfully and passed 44 of 45
selected test functions, but failed the new Unicode root-inheritance fixture.
The fixture was then changed to explicitly accept both NFC and NFD spellings
and to assert the direct root match. The corrected fixture passes against
both baseline and candidate in all four debug/release platform combinations.
This was a test-fixture correction; the production optimization did not change.
The newly queued full-app integration rerun remains a separate gate.

## Interpretation and limits

The default no-rule browser already skips the per-row visibility matcher, so
these results do not establish a general default-browsing speedup. Query-only
search reuses cached visibility and is outside the improvement claim.

These component measurements cover rebuilding an existing source tree's
visibility. They do not measure cold filesystem discovery, whole-window
responsiveness, rendering frame rate, playback CPU, energy, resident memory,
or allocation peaks.

The native evidence qualifies this macOS/Foundation/compiler combination.
The portable evidence is corroboration on Linux, with its documented source
adaptations. It must not be used as a substitute for the native measurements,
and neither cohort establishes results for every device or library.

The native controls do not support a universal no-regression claim. The
ASCII-path measurements are less consistent than the main Unicode-root case;
their winning-pair counts and full ranges are retained above.

Eight pairs from one host and compiler are limited evidence of the distribution
across user hardware and real libraries. The full workload matrix and raw
observations are retained so controls, variability, and scope can be inspected.

## Retained evidence and reproduction

Raw evidence is committed under
[`evidence/macos`](../Benchmarks/ManualVisibility/evidence/macos) and
[`evidence/linux`](../Benchmarks/ManualVisibility/evidence/linux).
Each directory contains `manifest.json`, `tests.json`, `verification.json`,
`calibrations.json`, `measurements.jsonl`, and `summary.json`.

The manifests retain exact source, staged-source, shared-input, and binary
hashes, host/compiler details, comparison heads, and timing boundaries.
Raw process records retain every individual duration, receipt cycle, pair
identity, process order, and cache counter. No unfavorable sample was removed.

The committed JSON values were recovered from each job's emitted evidence
bundle; formatting can differ from the original artifact files. CI artifacts
also contain build/test logs and staged Swift sources, with 14-day retention:
[native artifact](https://github.com/Jagalite/illiquid/actions/runs/40636025973/artifacts/12795008579)
and [portable artifact](https://github.com/Jagalite/illiquid/actions/runs/40639121107/artifacts/12795231330).

See [the benchmark README](../Benchmarks/ManualVisibility/README.md) for native
and portable commands, workload descriptions, and the source-comparison gates.
The baseline is intentionally fixed. Reusing the study after unrelated support
code changes requires explicit review and requalification.
