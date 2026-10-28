# Thumbnail sample planning

Research target: constructing the ordered, half-second timestamp list used by
foreground cache fallback, current-video storyboard preparation, and background
thumbnail generation. The production defaults request 6, 12, or 24 samples.

The baseline completes an entire binary-subdivision round before checking the
requested count, then copies the requested prefix. Short clips can keep probing
duplicate positions through all 128 divisions. The candidate reserves only the
bounded output size and stops when that ordered prefix is complete or all
possible half-second positions have been found.

## Reproduce

The baseline is main commit
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`.
Use a checkout containing that commit, Python 3.10+, and Swift 6.1 or later.
Run through the shared Kyoto queue when available, as required by AGENTS.md.
On a host without Kyoto, explain that limitation before running directly.
The driver serializes all builds and measurements.

```sh
python3 Benchmarks/ThumbnailSamplePlanning/run.py \
  --pairs 8 --target-ms 80 --output /tmp/illiquid-thumbnail-samples-new
```

The output directory must not already exist. Use `--mode tests` or `--mode benchmark`
to run one part of the campaign.

The driver compiles the complete, actual ThumbnailPolicy.swift from both the
pinned baseline and the checkout, using identical release flags. The existing
thumbnail policy and scheduling tests plus new exact-order regressions run
against both versions in debug and release. The regression oracle freezes the
old function; independent golden arrays and boundary/randomized inputs protect
against accidentally changing its arithmetic or ordering.

Timing uses a prebuilt corpus, a warmup, and eight alternating baseline/candidate
and candidate/baseline pairs per workload. Input construction, compilation,
process startup, result encoding, and correctness tests are outside the timer.
Each measured operation creates one plan; a common small checksum consumes its
count and selected timestamps. Matching checksums and output counts are required
for every pair. Timing and process CPU results are retained separately.

The two storyboard workloads call the public storyboard wrapper. Three
background workloads use the 6/12/24 presets; short clips exercise exhausted
quantization; 64 samples with zero focus exercise a complete-round control.
One-sample and invalid-duration cases cover very small workloads. Raw measurements,
calibration, source/test hashes, commands, compiler/host information, source
snapshots, and test logs are retained in the result directory and CI artifact.

## Scope

This is a component benchmark. It does not measure image decoding, disk reads,
cache hit rate, end-to-end hover latency, playback CPU, or energy. Large relative
gains in a small planning function must be interpreted with their absolute
nanoseconds per plan. The patch preserves the 128-division ceiling and existing
extreme-finite-double overflow behavior; it is not a numerical-behavior change.

## Results: Linux x86_64

[Research run 40637598746](https://github.com/Jagalite/illiquid/actions/runs/40637598746) completed successfully on
Ubuntu 24.04 / Linux x86_64 with Swift 6.4. The candidate source was compiled from
commit `40d9d1d4a70eba8ee7fcb1da7d0f476fd67e116f`; the baseline was the pinned
main commit above. [Retained evidence](evidence/linux-x86_64.json) contains all
160 measured samples, all calibration observations, paired distributions,
test-completion receipts, and source/harness/runner/test hashes.

These are medians of eight alternating before/after pairs, in **microseconds
per plan**. Negative change means less elapsed time. The corpus varies duration
and focus within each workload; the exact inputs are in Harness.swift.

| Workload (sample count) | Baseline µs | Candidate µs | Change | Faster pairs |
| --- | ---: | ---: | ---: | ---: |
| Movie storyboard (24) | 0.9137 | 0.4546 | -50.2% | 8/8 |
| 30-second storyboard (24) | 0.9057 | 0.4504 | -50.3% | 8/8 |
| Balanced background (12) | 0.5167 | 0.1972 | -61.8% | 8/8 |
| Economical background (6) | 0.3323 | 0.1109 | -66.6% | 8/8 |
| Extensive background (24) | 0.9754 | 0.4463 | -54.2% | 8/8 |
| Subsecond clip (24 requested) | 0.8964 | 0.0563 | -93.7% | 8/8 |
| 1–2.5-second clip (64 requested) | 1.1254 | 0.0911 | -91.9% | 8/8 |
| Full-budget control (64) | 2.4358 | 2.0803 | -14.6% | 8/8 |
| One sample with nonzero focus | 0.1609 | 0.0559 | -65.2% | 8/8 |
| Invalid-duration control | 0.0076 | 0.0075 | -0.1% | 5/8 |

Process CPU reductions closely match elapsed-time reductions (for example,
movie storyboard: -50.2%; balanced background: -61.8%). The valid workloads
improved in all eight paired comparisons. The invalid-duration control was
effectively unchanged (about 7.55 ns before and after); it hits the two-million
iteration cap and runs for about 15 ms, so its small fluctuations should not be
interpreted as a performance gain.

All **19 tests in three suites** passed for baseline and candidate in both
debug and release. Each configuration includes 17,828 complete-array,
bit-pattern differential comparisons and 176 additional golden/invariant
expectations in the new suite. The benchmark also verifies matching checksums
and output counts for every timed pair.

### Qualification boundary

The macOS component run was still queued when these results were recorded:
[run 40636506744](https://github.com/Jagalite/illiquid/actions/runs/40636506744).
No macOS timing or full-player/live-playback improvement is claimed by the Linux
results. The PR retains a macOS workflow for native confirmation. The production
source and benchmark inputs are identical between the Linux and macOS campaigns.

### Why these operations occur in the player

- `NativeTimelineThumbnailGenerator.cachedThumbnail` supplies the storyboard as
  fallback times after an exact image-cache miss.
- `ThumbnailBackgroundScheduler.runCurrent` prepares a 24-sample storyboard.
- The scheduler's background pass uses `samplesPerVideo` (presets: 6, 12, 24).

For a 7,200-second movie with zero focus and 24 requested samples, the baseline
tries 33 positions and performs 497 linear duplicate comparisons; early stopping
needs 25 probes and 277 comparisons. A subsecond clip needs one output but the
baseline tries both seeds plus 127 subdivision positions. These counts explain
the component mechanism; they are not claims about total playback work.

### Correctness argument

The planner appends unique timestamps in priority order and returns a prefix.
Once the requested count has been appended, later probes cannot change that
prefix. A short clip has only `Int(last * 2) + 1` available half-second positions,
so finding all of them also makes further probes redundant. The integer
conversion is guarded by a bound below 31.5 seconds, avoiding traps for extreme
finite input. The existing rounding expressions, focus behavior, count
clamping, ordering, and 128-division limit are unchanged.

