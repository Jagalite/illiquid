# Thumbnail sample prefix planning

## Result

Linux component qualification passed on 2026-10-28 with Swift 6.3.2 on an
x86_64 GitHub Actions runner. The normal 12/24-sample workloads used about
38–43% less CPU service time in this experiment. The short saturated clip
was effectively unchanged, and the unchanged nearby-sample control's
confidence interval included parity.

These are sub-microsecond planning improvements for the normal requests.
They do not establish an end-to-end decoding, hover, playback or energy
improvement. No macOS measurements are included in this evidence set; the
separate macOS workflow qualifies the application's target platform.

- [Successful Linux run](https://github.com/Jagalite/illiquid/actions/runs/40640011404)
- [macOS qualification run](https://github.com/Jagalite/illiquid/actions/runs/40638281297)
- Measured source/harness revision: `fbe1bd0e1a0d5b3ba1cdeaaf5ef4081fa65e9d5e`.
- Baseline revision: `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`.

CPU nanoseconds per call are separate medians. Speedups are medians of
paired baseline/candidate ratios, so they need not equal the ratio of the
two displayed medians. Intervals are 95% bootstrap intervals for that paired
median, using 10,000 resamples.

| Workload | Baseline CPU ns | Candidate CPU ns | Paired speedup | 95% interval |
| --- | ---: | ---: | ---: | --- |
| 6 samples, resumed video | 346.34 | 191.01 | 1.806× | 1.790–1.827× |
| 12 samples, resumed video | 512.62 | 304.62 | 1.684× | 1.671–1.690× |
| 12 samples, start position | 508.61 | 312.97 | 1.625× | 1.619–1.644× |
| 24 samples, resumed video | 953.77 | 545.99 | 1.739× | 1.724–1.796× |
| 24-sample storyboard | 912.79 | 547.57 | 1.660× | 1.653–1.672× |
| 64 samples, start position | 2430.92 | 2267.24 | 1.081× | 1.070–1.090× |
| 64 samples, resumed video | 2368.56 | 1991.64 | 1.193× | 1.154–1.209× |
| 1 sample, resumed video | 175.11 | 64.80 | 2.713× | 2.643–2.746× |
| 0.2-second clip, 64 requested | 884.79 | 65.60 | 13.432× | 12.915–13.648× |
| 2-second clip, 12 requested | 1072.14 | 1069.86 | 1.003× | 1.000–1.009× |
| Unchanged nearby-sample control | 252.15 | 253.61 | 0.995× | 0.986–1.008× |

[Raw observations](evidence/linux/observations.jsonl),
[calibration](evidence/linux/calibration.json), and
[summary](evidence/linux/summary.json) retain CPU and wall times, output
fingerprints, checksums, capacity, iteration counts, pair order and all
individual speedups. The [manifest](evidence/linux/manifest.json) records
compiler, input-source and built-binary fingerprints.
The [independent audit](evidence/linux/audit.json) recomputed 2,916 checks
from the retained records with zero discrepancies; it did not independently
regenerate bootstrap resamples.

## Change and production relevance

`ThumbnailPolicy.samples` previously completed an entire subdivision round
before copying the requested prefix. For a 120-second video resumed at
42.3 seconds, a 12-sample request generated 17 distinct values before keeping
12. A 7,200-second storyboard generated 32 before keeping 24.
The candidate stops as soon as that ordered prefix exists and returns the
initial sample immediately when the request needs only one timestamp or
the clip has only one possible half-second timestamp.

The focus normalization, clamping, quantization, deduplication and subdivision
arithmetic are unchanged. Extreme finite inputs retain their existing
overflow behavior; fixing those semantics would be separate work.

The [scheduler](../../Sources/IlliquidApp/App/ThumbnailBackgroundScheduler.swift)
uses 12 samples by default, 6/12/24 in presets, and bounds requests to 1...64.
The 24-sample storyboard is also used by
[cached-thumbnail fallback](../../Sources/IlliquidNativePlayback/Media/NativeTimelineThumbnailGenerator.swift)
and [storyboard protection](../../Sources/IlliquidPlayer/Player/PlaybackController.swift).

## Allocation tradeoff

Returning the generated array directly avoids a prefix copy but can retain
additional geometric spare capacity. These are observed array capacities
on this Linux allocator; process memory and allocation counts were not measured.

| Returned samples / fixture | Baseline capacity | Candidate capacity | Additional Double slots |
| --- | ---: | ---: | ---: |
| 12, start or resume | 13 | 15 | 2 |
| 24, storyboard or resume | 25 | 31 | 6 |
| 64, resume | 65 | 127 | 62 |

Those differences correspond to 16, 48 and 496 bytes of Double element
capacity per returned array, excluding allocator overhead. Other measured
cases retained the same capacity, including the 64-sample start-position
case, which already retained 127 slots in the baseline. Output count remains
bounded to 64. This is a CPU optimization with an explicit capacity tradeoff,
not a claim of lower retained memory.

## Correctness

All 20 test declarations across the existing policy suite, existing scheduling
regressions, and new prefix regression suite passed against both variants in
debug and release. [Test receipts](evidence/linux/tests.json) retain the summaries.

The [4,732-case differential](evidence/linux/differential.json) compared every
output timestamp's IEEE-754 bits. Its complete output digest was identical
across all four builds. Cases cover invalid durations/foci, signed zero,
subnormal and extreme finite values, half-second boundaries, duplicate focus,
clamped counts including Int.min/Int.max, and 512 deterministic generated
inputs. Golden 12/24-sample sequences independently check established order.

## Reproduce

On an isolated host without the shared Kyoto queue:

```sh
python3 Benchmarks/ThumbnailSamplePrefix/run.py \
  --output /tmp/thumbnail-sample-prefix --pairs 12 --target-ms 80
```

Where Kyoto is available, submit the entire command through it and add
`--kyoto-worker` to the submitted command. Inspect the job's show/logs/wait
receipts as required by `AGENTS.md`. The harness refuses a direct build there.
All builds and tests are serialized.

The frozen baseline is the complete production file from
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`, Git blob
`cf3b96706f34ba5c43041d650f4c9f6217e340cc`. The runner verifies that blob before
building it. It copies the complete candidate file without extracting or
rewriting the measured function. Each variant is compiled into a separate
`IlliquidCore` module, without cross-module optimization, then called by the
same driver source, built separately for each variant.

Release timings use 12 fresh-process AB/BA pairs per workload and the same
calibrated iteration count in each pair. Workload order rotates each pair.
Setup, warmup, full-output validation and JSON are outside the timed region.
Production calls, count/first/last consumption and array lifetime are inside.
Every timing row has a checked observable checksum.

The branch-only portable workflow uses the official `swift:6.3.2-jammy`
container and does not cancel the macOS workflow. Its exact image digest
and hosted-run identifiers are retained in [provenance](evidence/linux/provenance.json).
After merging, the macOS workflow runs for relevant pull requests; either
workflow can also be dispatched manually.
