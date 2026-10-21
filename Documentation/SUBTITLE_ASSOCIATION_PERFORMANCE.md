# External subtitle association performance research

## Decision status

**Outcome: no production PR.** The candidate passed all completed correctness
checks, but the fixed independent repeat did not meet the cross-workload
performance criterion. Broad-prefix256 passed its per-case repeat criterion;
broad-prefix1024 produced only 13/20 faster pairs against the required 15/20.

The acceptance rule was recorded before the repeat's results in
[commit bd3dece1](https://github.com/Jagalite/illiquid/commit/bd3dece1a978502ed42d757ab749cc80beb03afb).
It was not relaxed after observing the results. All **1,152 native timing
observations** remain available across separate campaigns. The candidate stays
on this experimental branch for reproduction; it is not proposed for production.
No additional sampling is planned.

## Candidate and scope

The selected candidate changes one expression in
[ExternalSubtitleMatcher](../Sources/IlliquidCore/Playlist/ExternalSubtitleMatcher.swift).
Fuzzy scoring previously copied the shared media-token prefix into an Array
solely to sum its String character counts. The candidate reduces the prefix
slice directly:

```swift
let sharedWeight = mediaTokens.prefix(sharedCount).reduce(0) { $0 + $1.count }
```

The ordered strings, initial zero, character-count operations, and addition
order are identical. Existing score thresholds and tie rules are preserved.
The original dictionary-finalization loop and all cancellation polls are retained.

The measured operation is a complete in-memory subtitle association call on
prepared URLs. The target workloads have eight generic subtitle filenames
whose token prefix matches every episode candidate. Exact filenames take an
earlier scoring path and serve as controls. The study does not measure file I/O,
total folder-open latency, playback CPU, frame rate, allocations, or battery life.
The prevalence of these broad-prefix inventories in user folders is unknown.

## Inputs and reproducibility

- Frozen main: `a2de305c8dbcaa81aac1477df7c9a0017c14eae3`.
- Baseline matcher SHA-256: `38f10f619d3a8f09bb0b0e4b0c92ff9696338722292e59c5e1fbd561a6d928eb`.
- Selected matcher SHA-256: `419a27ac4c5d628598ed00d0820cf66b187336e3e374d350cc0c2a2b68962af8`.
- Native qualification revision: `aad9d161c483f024e257b6cfe95ccb29cc9b9f83`.
- Repeat revision: `4d74b2fe33b2b86cf5e7c3fb6254423926e792a6`.
- Native hosts report Apple M1 (Virtual), arm64 macOS 26.6.2, Apple Swift 6.3.3,
  and locale `en_US`.

The [benchmark README](../Benchmarks/SubtitleAssociation/README.md) explains the
fixtures and commands. The frozen source and helper files are included with
Git blob and SHA-256 checks. Compilation consumes staged copies of production
sources, tests, and driver. Manifests identify the actual bytes, compiler,
optimized build flags, build products, and runner.

Use the measured revision and an empty output directory to reproduce qualification:

```sh
git checkout aad9d161c483f024e257b6cfe95ccb29cc9b9f83
python3 Benchmarks/SubtitleAssociation/run.py \
  --output /tmp/illiquid-subtitle-qualification --pairs 12 --target-ms 250
```

Each sample is a fresh process. Baseline and candidate run serially in balanced
AB/BA pairs with equal iteration counts. A baseline CPU pilot calibrates the
iterations. Fixture creation, warmup, verification, and serialization are outside
timing; association, result-count consumption, and destruction are included.
Both process CPU and elapsed time are recorded. No sample is discarded, no
control time is subtracted, and timing percentages are not CI pass/fail gates.

The zero-media/zero-subtitle control is only tens of nanoseconds per call. Its
32-iteration pilot materially underestimates the work needed for the requested
interval; actual baseline intervals in qualification were 7.5–13.3 ms. It is
retained in the raw data but supplies no optimization claim. The focused repeat
uses nonzero controls and excludes this degenerate case.

## Correctness qualification

The selected source passed **31 tests in all four configurations**: baseline
debug/release and candidate debug/release. Six new test functions cover natural
ordering and duplicates, ancestor/descendant tie clearing, the fuzzy specificity
threshold and Unicode, qualifier-like title suffixes, original URL keys, and
checkpoint-by-checkpoint cancellation with mixed zero/one/multiple subtitles.

Each implementation also passed **52 independently expected complete mappings**:
17 timed fixtures plus nine edge fixtures, each in original and reversed input
order. Exact original URL keys and ordered subtitle arrays are compared between
implementations. Their common verification digest is
`7e2caa1957dead8abe947205652984c8d0b497b1ecd89261dcd149085b1c5d73`.
Timed count checksums supplement those full comparisons.

See the [qualification run](https://github.com/Jagalite/illiquid/actions/runs/39667662212)
and [retained test receipts](../Benchmarks/SubtitleAssociation/results/native-macos-20261021-qualification/test-receipts.txt).
The full application/native integration suite was not started for this study:
the performance candidate did not qualify for a production PR.

## Discovery and rejected alternatives

The [discovery run](https://github.com/Jagalite/illiquid/actions/runs/39666919832)
retains all 464 observations under
[the discovery evidence directory](../Benchmarks/SubtitleAssociation/results/native-macos-20261021-discovery).
Four mechanisms were measured separately:

| Candidate | Decision after discovery |
| --- | --- |
| Guard-only finalization | Rejected; several controls regressed and there was no compelling broad improvement. |
| Indexed dictionary-value finalization | Not promoted; modest gains were mixed with effects in untouched empty controls. |
| Direct prefix reduction | Selected for full qualification; broad-prefix1024 had 4/4 CPU and wall wins, a 5.75% median paired CPU reduction, and CPU ratios 0.937–0.952. |
| Indexed finalization plus prefix reduction | Not promoted; a larger target estimate was accompanied by wide variation and an empty-control slowdown. |

The selected discovery target's CPU medians were 9.3735 ms → 8.82894 ms.
Sparse1024's apparently large 6.99% loss from marginal medians was only a 1.09%
median within-pair loss, with a large outlier. Both statistics and every sample
are retained. This motivated the complete qualification and the control checks.

Discovery alternatives are reproducible through
[explore.py](../Benchmarks/SubtitleAssociation/explore.py). Their four-pair
campaigns are exploratory and are not pooled with qualification.

## Full selected-source qualification

Twelve pairs per workload targeted 250 ms of baseline CPU time. The complete
campaign contains **408 observations across 17 workloads**.
[Raw data, manifests, calibration, summaries, and receipts](../Benchmarks/SubtitleAssociation/results/native-macos-20261021-qualification)
are retained without exclusions. A positive percentage means less candidate time.

| Workload | Baseline CPU ms | Candidate CPU ms | CPU reduction from medians | Median paired CPU reduction | Faster CPU / wall pairs |
| --- | ---: | ---: | ---: | ---: | ---: |
| one_to_one_1 | 0.026 | 0.027 | -2.58% | -2.02% | 5/12 · 6/12 |
| one_to_one_16 | 0.410 | 0.439 | -6.93% | -5.87% | 3/12 · 4/12 |
| one_to_one_256 | 7.793 | 8.074 | -3.60% | -1.68% | 5/12 · 5/12 |
| one_to_one_1024 | 28.597 | 27.645 | +3.33% | +1.97% | 9/12 · 9/12 |
| two_subtitles_16 | 0.653 | 0.694 | -6.37% | +2.60% | 7/12 · 7/12 |
| two_subtitles_256 | 10.555 | 9.933 | +5.89% | -1.55% | 5/12 · 4/12 |
| multilingual_16 | 1.974 | 1.810 | +8.31% | +6.94% | 9/12 · 8/12 |
| multilingual_256 | 29.962 | 31.409 | -4.83% | -7.32% | 4/12 · 4/12 |
| sparse_1024 | 17.891 | 16.891 | +5.59% | +8.62% | 10/12 · 9/12 |
| unrelated_1024 | 23.582 | 23.817 | -1.00% | +3.09% | 7/12 · 7/12 |
| unsupported_1024 | 15.961 | 15.141 | +5.13% | +0.47% | 6/12 · 6/12 |
| empty_0 | 0.000088 | 0.000079 | +10.29% | +12.17% | 10/12 · 9/12 |
| empty_16 | 0.007 | 0.008 | -3.99% | -5.18% | 4/12 · 4/12 |
| empty_1024 | 0.464 | 0.484 | -4.43% | -5.06% | 4/12 · 4/12 |
| broad_prefix_256 | 4.924 | 4.390 | +10.86% | +11.51% | 11/12 · 11/12 |
| broad_prefix_1024 | 17.871 | 17.716 | +0.86% | +3.97% | 7/12 · 6/12 |
| unicode_256 | 7.636 | 7.218 | +5.47% | +0.59% | 6/12 · 7/12 |

Broad-prefix256 improved in 11/12 pairs on both clocks. Broad-prefix1024 had
only 7/12 CPU and 6/12 elapsed-time wins: its median paired CPU reduction was
3.97%, while the reduction computed from marginal CPU medians was only 0.86%
and elapsed-time medians regressed 2.08%.

Untouched controls also moved substantially in both directions. In particular,
empty16 and empty1024 had approximately 5% median paired CPU losses, while
sparse1024 had an 8.62% gain. These shifts cannot be attributed to executing
the selected fuzzy expression, which those fixtures bypass. This run does not
justify a claim of no regressions or a clean 1024-episode performance result.

## Fixed independent repeat

The [repeat run](https://github.com/Jagalite/illiquid/actions/runs/39668955054)
completed successfully using unchanged selected production, test, driver, and
runner bytes, twenty pairs, and a 300 ms target. Its seven cases were fixed before inspecting results:

- broad_prefix_256 and broad_prefix_1024;
- one_to_one_16, multilingual_256, and sparse_1024;
- empty_16 and empty_1024.

The practical decision rule recorded before the repeat was:

1. Both broad-prefix targets must have positive median paired CPU and wall
   reductions, at least 15/20 faster pairs on both clocks, and positive median
   improvements separately in the ten AB and ten BA pairs.
2. Exact and empty controls must not show sustained material slowdowns.
3. Keep the campaigns separate and retain all earlier data.
4. If this repeat remains mixed, conclude that the performance evidence is
   inconclusive and do not open a production PR. Do not collect further samples.

This is a practical engineering acceptance rule, not a claim of a formal
statistical confidence level.

## Final repeat results and decision

The repeat contains **280 observations** and passed the same 52 complete output
comparisons. It ran in benchmark-only mode because the exact selected production
and test bytes had already passed all four native debug/release configurations.
All seven workloads alternated AB/BA with ten pairs starting in each order.

[Raw repeat evidence and machine-readable decision](../Benchmarks/SubtitleAssociation/results/native-macos-20261021-repeat)
include every observation, calibration, source/build receipt, summary, order
breakdown, and the acceptance evaluation. A positive percentage means less
candidate time. Paired reductions are 100 × (1 − the median of the within-pair
candidate/baseline ratios). The last column contains separate marginal medians
and need not imply the same percentage.

| Workload | Median paired CPU reduction | Median paired wall reduction | Faster CPU / wall pairs | Baseline → candidate CPU medians (ms) |
| --- | ---: | ---: | ---: | ---: |
| broad_prefix_256 | +7.13% | +6.92% | 16/20 · 16/20 | 3.807 → 3.619 |
| broad_prefix_1024 | +9.18% | +9.33% | 13/20 · 13/20 | 13.571 → 13.622 |
| one_to_one_16 | -0.15% | -0.18% | 10/20 · 10/20 | 0.287 → 0.289 |
| multilingual_256 | -1.51% | +1.73% | 8/20 · 10/20 | 28.185 → 28.745 |
| sparse_1024 | +2.91% | +2.65% | 11/20 · 12/20 | 16.116 → 17.018 |
| empty_16 | -2.93% | -2.48% | 9/20 · 9/20 | 0.010 → 0.011 |
| empty_1024 | +1.32% | +3.57% | 11/20 · 11/20 | 1.490 → 1.427 |

Broad-prefix256 met the planned per-case condition: 16/20 wins on both clocks,
with positive median reductions in both orders. AB pairs showed 6.21% CPU and
6.14% wall reductions; BA pairs showed 7.95% CPU and 7.94% wall reductions.
The median within-pair CPU saving was 0.334 ms per association.

Broad-prefix1024 did not meet the planned minimum: only 13/20 wins on either
clock. Its positive paired estimates were accompanied by CPU ratios ranging
from 0.681 to 1.364 and nearly unchanged marginal CPU medians
(13.571 ms → 13.622 ms, a 0.37% slowdown). The two order groups had positive
medians, but that does not repair the failed repeatability requirement.

The controls continued to vary. None had 15/20 consistent losses on both
clocks, but their wide ranges and order-dependent effects do not establish
absence of regression. In particular, sparse1024's paired CPU estimate was
+2.91% while its marginal medians regressed 5.60%; both are retained.

The result supports a narrow positive signal in the 256-episode fixture. It
does not satisfy the fixed criteria for proposing the production change.
The experiment ends with **no PR**. No measurements were pooled, removed, or
reclassified as controls after the repeat.

A separately opened [ASCII subtitle tokenization PR](https://github.com/Jagalite/illiquid/pull/69)
changes filename tokenization, while this study changes fuzzy shared-prefix
weighting. This study did not modify that PR or measure the combined changes.

## Evidence retention

Versioned JSON payloads were extracted verbatim from completed job logs, removing
only log timestamps and marker prefixes. Original decimal checksum literals are
preserved. Independent recomputation verified counts, pairing, order, checksums,
locales, and reported summaries.

Each evidence directory includes a CI receipt with the measured revision,
run/job identity, artifact digest, and expiration date. CI artifacts additionally
contain full source snapshots, complete verification mappings, commands, and
full build/test logs. The artifacts expire after fourteen days; the versioned
raw measurements and frozen inputs remain available.
