# Avoiding repeated normalized subtitle exact checks

## Outcome and qualification status

A small complete-association CPU improvement was measured on Linux x86_64 with
Swift 6.4. Plain filenames with one extended-name subtitle per media file used
**1.0–1.9% less CPU time**, based on the median of paired candidate/baseline
ratios. The 256- and 4,096-file cases improved by 1.90% and 1.85%, respectively.

This is **portable component evidence**. Native macOS qualification remains
pending in [run 40638279368](https://github.com/Jagalite/illiquid/actions/runs/40638279368).
The dependent PR should remain a draft until native results establish that the
change is useful on the player's target platform. No whole-player speedup is claimed.

The successful portable run is
[40639463313](https://github.com/Jagalite/illiquid/actions/runs/40639463313),
job [122653960303](https://github.com/Jagalite/illiquid/actions/runs/40639463313/job/122653960303),
completed on 2026-10-28. It used Swift 6.4 (`swift-6.4-RELEASE`),
target `x86_64-unknown-linux-gnu`, and Linux 6.17.0-1022-azure with glibc 2.39.
The measured candidate is `9d5dfceeecdaa0579d7979af71316da394d62c35`.
Subsequent evidence/documentation commits leave its measured source, tests,
runner, and driver unchanged.

## Why the change is valid

The private scorer receives both the raw media tokens and a normalized prefix
that removes trailing media qualifiers. Both call sites construct the normalized
value by taking a prefix of the raw array.

The raw-name exact check runs first to preserve release-specific matching and
titles ending in words such as "Us". When that check fails and no media tokens
were removed, the next normalized check repeats the same pure predicate on the
same sequence. The candidate skips that duplicate check when the counts match.

For example, matching `Episode.001.mkv` with
`Episode.001.Extended.en.srt` otherwise compares the media prefix twice before
fuzzy scoring. A qualified media filename still takes the normalized fallback
because its raw and normalized token counts differ.

The change adds no cache or retained state. Exact-match precedence, the fallback
after qualifier removal, fuzzy scores, ambiguity, subtitle ordering, and
cancellation checkpoints retain their existing behavior.

## Separate from the parent optimization

This is a follow-up to [PR #119](https://github.com/Jagalite/illiquid/pull/119).
The baseline is pinned to its head,
`1063508a14bbc7a08669171880069c4df9472350`, which already avoids the temporary
array in fuzzy prefix weighting. The parent study's larger gains are **not**
included in this experiment's reported improvement.

The runner's original baseline and 13 default timed workloads remain available.
The new plain-name fixtures are always verified but are timed only when selected
with `--case`. The unchanged driver and shared measurement protocol are reused.

## Results

Times are independently calculated variant medians. A paired ratio below 1 favors
the candidate; it need not equal the ratio of the two displayed medians.
Intervals are descriptive paired bootstrap intervals for this run, not estimates
across a population of machines.

| Complete association workload | Baseline CPU ms | Candidate CPU ms | Paired CPU ratio | Descriptive 95% interval |
| --- | ---: | ---: | ---: | --- |
| 1 plain media file, 1 extended-name subtitle | 0.0058 | 0.0057 | 0.9876 | [0.9833, 0.9909] |
| 16 plain media files, 1 subtitle each | 0.0830 | 0.0818 | 0.9897 | [0.9807, 0.9960] |
| 256 plain media files, 1 subtitle each | 1.3599 | 1.3308 | 0.9810 | [0.9761, 0.9827] |
| 4,096 plain media files, 1 subtitle each | 21.9178 | 21.4951 | 0.9815 | [0.9767, 0.9852] |
| 256 plain media files, 8 languages each | 22.3695 | 22.1813 | 0.9918 | [0.9875, 0.9949] |
| 256 long plain names, 8 languages each | 28.5129 | 28.3100 | 0.9925 | [0.9909, 0.9963] |
| 256 Unicode plain names, 8 languages each | 50.5243 | 50.2833 | 0.9959 | [0.9907, 0.9984] |
| 256 plain media files, 8 generic subtitles | 1.0236 | 1.0128 | 0.9868 | [0.9834, 0.9902] |
| 256 qualified media files, 8 languages each (control) | 22.5246 | 22.4804 | 0.9971 | [0.9944, 1.0023] |
| 256 long qualified names, 8 languages each (control) | 28.5742 | 28.5586 | 1.0000 | [0.9969, 1.0020] |
| 256 plain exact matches (control) | 1.3192 | 1.3161 | 1.0020 | [0.9917, 1.0035] |
| 256 qualified exact matches (control) | 1.5532 | 1.5464 | 0.9986 | [0.9948, 1.0007] |
| 256 qualified names, 8 generic subtitles (control) | 1.2482 | 1.2523 | 1.0019 | [0.9959, 1.0082] |
| 256 media files, 256 unrelated subtitles (control) | 1.0277 | 1.0232 | 0.9953 | [0.9919, 0.9974] |
| 256 media files, no subtitles (control) | 0.0634 | 0.0636 | 1.0022 | [0.9774, 1.0148] |

The eight-language plain ancestor cases improved by about 0.4–0.8%; the generic
plain-prefix case improved by 1.3%. The unchanged control medians stayed within
0.5% of parity. The unrelated control itself moved by about 0.47%, so effects
of that size should be interpreted cautiously. The empty-input control had
wider variation; all samples, including outliers, are retained. No repeated
control slowdown was established in this run.

Both process CPU and elapsed time are retained in the raw evidence. For the
256- and 4,096-file plain single-subtitle workloads, median paired elapsed-time
reductions were 1.90% and 1.86%.

## Method and correctness

Separate optimized Swift modules compile the full baseline or candidate matcher
and the same two production dependencies. Each timed iteration includes the
entire association call, result consumption, and result destruction. Fixture
construction, verification, three warmup iterations, process startup, and builds
are outside the timed interval.

Fifteen workloads each use 16 fresh-process pairs, alternating AB/BA order, with
identical iteration counts within each pair. Calibration targets 250 ms of process
CPU time on the slower variant, with at least five associations per sample.
No measurements are discarded and no control time is subtracted. The calibration
value is a target: the one-file cohort actually recorded about 76.8–79.5 ms of
CPU time per sample; all actual durations can be recovered from the raw rows.

All **44 tests in five suites passed** against both implementations in debug and
release, with warnings treated as errors. The added table checks exact scores and
associations for raw-title precedence, release-specific raw matching, normalized
fallback after qualifier removal, both fuzzy prefix directions, mismatches, and
Unicode width/diacritic normalization. Existing tests also exercise ties,
duplicates, unsupported formats, qualifier-only names, and cancellation.

The driver independently checks **30 complete fixture mappings**, in forward and
reversed input order, against both implementations. All **480 timed observations**
have matching expected/consumed checksums. An independent audit verifies the 240
pairings, equal iteration counts, AB/BA order, exact UInt64 checksums, and 150
CPU/wall summary values. A second audit also reproduced all 60 bootstrap interval
endpoints and independently recomputed every timed output checksum. All 527
recorded commands succeeded. `expected_fuzzy_scores` is derived from fixture
construction; it is not an instrumented execution counter.

Full emitted receipts, raw observations, calibration, commands, and test/build
logs are retained in [evidence/exact-guard-linux](evidence/exact-guard-linux/).
The source diff in that evidence contains only the normalized-check guard.

## Reproduce

Requires Swift 6.1+ and Python 3.9+, plus the pinned baseline in local Git history.
Follow the repository's Kyoto queue requirement when it is available; these
isolated hosted runners lack Kyoto and serialize their builds. Use a fresh output
directory.

```sh
python3 Benchmarks/SubtitleFuzzyPrefix/run.py \
  --baseline-ref 1063508a14bbc7a08669171880069c4df9472350 \
  --case ancestor_plain_1_1 \
  --case ancestor_plain_16_1 \
  --case ancestor_plain_256_1 \
  --case ancestor_plain_4096_1 \
  --case ancestor_plain_256_8 \
  --case ancestor_long_plain_256_8 \
  --case ancestor_unicode_plain_256_8 \
  --case plain_prefix_256_8 \
  --case ancestor_qualified_256_8 \
  --case ancestor_long_qualified_256_8 \
  --case exact_plain_256 \
  --case exact_256 \
  --case fuzzy_256_8 \
  --case unrelated_256 \
  --case empty_256 \
  --pairs 16 --target-ms 250 --output /tmp/subtitle-exact-check
```

`--baseline-ref` is resolved to an immutable commit before reading baseline
sources. `--case` limits timing only; every fixture still undergoes full output
verification. The original default timing cohort is unchanged.

## Limits

These are synthetic warm component workloads. Real filename distributions,
invocation frequency, folder-opening latency, UI responsiveness, decoding,
playback CPU, frame rate, energy use, allocation counts, and RSS have not been
measured. Linux results do not establish the size or existence of a macOS
performance improvement.
