# Bitmap subtitle timeline lookup

`BitmapSubtitleTimeline` stores events in timestamp order. Lookup previously
searched backward with `last(where:)`, visiting every future event until it
reached the requested position. The revised candidate checks the newest two events directly, expands backward
in blocks of 2, 4, 8 and so on, then uses an upper-bound search only within the
resulting bracket. Insertion,
pruning, expiration, generation handling and memory ownership are unchanged.

`SubtitlePipeline.renderedFrame` queries this timeline under its lock after
the exact-millisecond/geometry cache check. Subtitle read-ahead defaults to
30 seconds, and `MediaSession` prunes events before playback position minus
30 seconds. A middle-of-window query therefore exercises a plausible mixture
of past and future events. Actual event occupancy has not been profiled:
128 is the default capacity, not a claim about typical playback.

## Reproduce

Native validation requires macOS, Swift 6.1+ and Python 3.10+. Reuse the insertion
suite's component runner with the lookup suite selected:

```sh
python3 Benchmarks/BitmapSubtitleTimeline/run.py --suite lookup --tests-only \
  --output /tmp/illiquid-bitmap-lookup-tests
python3 Benchmarks/BitmapSubtitleTimeline/run.py --suite lookup \
  --pairs 8 --target-ms 80 --max-sample-ms 1500 \
  --output /tmp/illiquid-bitmap-lookup-timing
```

For explicitly portable Linux measurements, add `--portable` to either lookup
command. This conditionalizes only standalone CoreGraphics imports in staged
sources and the driver; Foundation supplies real geometry types. Original and
compiled source hashes are retained. Portable measurements do not qualify macOS
performance. The default insertion suite still requires macOS.

Use a new empty output directory for each attempt and run one benchmark at a
time. Follow `AGENTS.md`: submit builds through Kyoto when available; otherwise
explain its absence before compiling directly. The focused GitHub workflow
does this automatically. Omitting `--suite lookup` preserves the original
insertion suite and its historical frozen baseline.

The lookup baseline is the complete production timeline from main commit
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`, after the earlier insertion improvement.
Its SHA-256 is checked before execution. Both variants compile the entire
timeline and memory-budget source files plus the complete unchanged
`ASSRenderedRegion` declaration extracted from `LibassContext.swift`. No
FFmpeg, libass, playback fixtures, app launch or behavioral mocks are needed.

The optimized production module is compiled separately from the driver with
`-enable-testing`, so the compiler cannot specialize the implementation around
the driver's known fixtures. Geometry, `Data` and memory leases use native types.

## Workloads and verification

Twenty-nine workloads cover empty timelines; first, middle, newest,
after-newest and before-first positions; penultimate positions at 2, 8, 32 and
128 entries; and forward/shuffled mixed query streams at 8, 32 and 128 entries.
One-entry/newest controls protect the common sparse-subtitle case.

The timeline and queries are prepared before timing. Each measured operation is
one production `composition(at:)` call plus scalar checksum consumption.
Simple positions use batches of 256 queries; mixed cases use six points per
entry plus before/after controls. Mixed fixtures contain indefinite captions,
active and expired finite captions, and empty clear events. No insertion,
pruning, fixture generation or full receipt serialization is timed.

An independent forward linear oracle verifies full result receipts before and
after timing, including exact timestamp bits, duration, complete pixel data,
geometry, forced flags, lease presence and timeline accounting. The timed
checksum consumes selected timestamps, payload markers and present/nil state.
Baseline and candidate receipts and checksums must agree in every pair.

The unchanged ordering and memory-budget tests plus the focused lookup tests
run against both variants in debug and release, with warnings treated as
errors. They cover small and custom capacities, representable neighbors of
every timestamp, signed-zero replacement, invalid input, duration boundaries,
clear events, end-time overflow/rounding, reset/pruning, generation rejection,
value copies, randomized mixed histories and real memory-lease lifetimes.

## Measurement protocol

Eight fresh-process pairs alternate AB/BA ordering. Each pair uses identical
iterations and fixture seed. Calibration targets 80 ms on the faster variant,
capped at an estimated 1.5 seconds on the slower one. Warmup and calibration are
excluded from the measurements; all actual timing samples are retained without
outlier removal or control subtraction. Results are nanoseconds per lookup,
including checksum consumption.

Outputs include raw measurements, full query receipts, commands, source/test/
driver/binary hashes, compiler version and host metadata. The workflow uploads
complete evidence and prints compact unmodified summaries for remote review.

## Interpretation

These are warm native component measurements. They do not measure real subtitle
occupancy or query frequency, lock contention, video decoding, bitmap expansion,
GPU work, frame rate, whole-player CPU, memory footprint or energy. Small-window,
newest and penultimate controls matter alongside the larger-window speedups.

## Results

### First candidate: global binary search (rejected)

[Portable run 40639719722](https://github.com/Jagalite/illiquid/actions/runs/40639719722)
used Swift 6.4 on x86_64 Linux (Ubuntu 24.04 runner). Both variants passed
25 tests in three suites in debug and release. All 464 measured samples across
29 workloads and eight pairs had matching receipts and checksums.

This version checked the newest event, then searched the whole remaining prefix.
It improved large-buffer queries but consistently regressed near-newest and
small-window cases, so it was not selected for the PR.

| Workload | Baseline median ns/query | Binary candidate median ns/query | Reduction |
| --- | ---: | ---: | ---: |
| First event, 128 entries | 76.01 | 25.41 | 66.6% |
| Middle event, 128 entries | 45.92 | 25.23 | 45.0% |
| Penultimate event, 128 entries | 19.90 | 25.67 | -29.0% |
| Newest event, 128 entries | 19.74 | 20.27 | -2.7% |
| Forward mixed queries, 8 entries | 18.09 | 18.96 | -4.8% |

Positive reductions mean less time. Negative reductions are regressions.
These values include lookup, loop and scalar checksum overhead; they are not
player frame-time measurements. Original source/driver/test hashes, all raw
measurements and calibration samples, commands, test logs and summaries are
retained under [the first experiment's evidence](evidence/20261028-linux-binary).
Complete query receipts are also in that run's CI artifact (14-day retention).

### Revised candidate: bounded backward search

[Portable run 40640675998](https://github.com/Jagalite/illiquid/actions/runs/40640675998)
tested commit `882be3d8ec4415079b4ed64e093d320f968c7c72` on Swift 6.4,
x86_64 Linux, with four hosted vCPUs reporting AMD EPYC 9V74. The complete
hardware description is retained in the manifest. Both variants passed the
same 25 tests in three suites in debug and release. All 464 measured samples
again had identical result receipts and checksums.

The new search checks the newest two events directly, expands backward in
bounded blocks, and searches only the resulting bracket. Large-window active
queries improved by 36-58% in this cohort. Most small-window and tail controls
changed by less than half a nanosecond, but `newest-128` regressed by 1.24 ns
(8.8%), with the candidate slower in seven of eight pairs. This result is
retained and is not being dismissed as noise.

| Workload | Baseline median ns/query | Revised median ns/query | Reduction | Candidate faster pairs |
| --- | ---: | ---: | ---: | ---: |
| `empty` | 3.58 | 3.58 | 0.0% | 5/8 |
| `first-8` | 17.05 | 16.92 | 0.7% | 5/8 |
| `first-32` | 24.92 | 19.66 | 21.1% | 8/8 |
| `first-128` | 59.46 | 24.98 | 58.0% | 8/8 |
| `middle-8` | 15.98 | 16.11 | -0.8% | 2/8 |
| `middle-32` | 19.93 | 18.11 | 9.1% | 8/8 |
| `middle-128` | 35.48 | 22.61 | 36.3% | 8/8 |
| `newest-1` | 15.14 | 15.09 | 0.3% | 4/8 |
| `newest-8` | 15.04 | 14.90 | 1.0% | 4/8 |
| `newest-32` | 15.05 | 15.05 | 0.0% | 5/8 |
| `newest-128` | 14.09 | 15.33 | -8.8% | 1/8 |
| `after-newest-1` | 15.04 | 15.09 | -0.3% | 4/8 |
| `after-newest-8` | 15.04 | 15.03 | 0.1% | 3/8 |
| `after-newest-32` | 15.06 | 15.01 | 0.3% | 5/8 |
| `after-newest-128` | 15.06 | 15.32 | -1.7% | 2/8 |
| `before-first-1` | 3.86 | 3.58 | 7.1% | 8/8 |
| `before-first-8` | 5.81 | 4.55 | 21.7% | 8/8 |
| `before-first-32` | 16.00 | 6.63 | 58.6% | 8/8 |
| `before-first-128` | 49.05 | 9.78 | 80.1% | 8/8 |
| `penultimate-2` | 15.50 | 15.68 | -1.2% | 1/8 |
| `penultimate-8` | 15.33 | 15.43 | -0.6% | 3/8 |
| `penultimate-32` | 15.30 | 15.41 | -0.7% | 4/8 |
| `penultimate-128` | 15.31 | 15.74 | -2.8% | 4/8 |
| `mixed-forward-8` | 14.06 | 14.21 | -1.1% | 0/8 |
| `mixed-forward-32` | 19.06 | 17.86 | 6.3% | 8/8 |
| `mixed-forward-128` | 39.04 | 23.60 | 39.5% | 8/8 |
| `mixed-shuffled-8` | 14.39 | 14.38 | 0.1% | 3/8 |
| `mixed-shuffled-32` | 18.99 | 18.41 | 3.1% | 8/8 |
| `mixed-shuffled-128` | 36.97 | 23.56 | 36.3% | 8/8 |

The full records are under [revised-candidate evidence](evidence/20261028-linux-galloping).
Compare baseline and candidate within each cohort. Absolute nanoseconds from
the initial and revised runs must not be pooled or compared as if they were
collected on the same host. The first run did not collect a CPU model; the
revised run records it explicitly.

### Predeclared stability check

The source, driver and tests remain unchanged. A separate check repeats only
`newest-128`, `newest-32` and `after-newest-128` with 16 balanced pairs,
a 250 ms calibration target and a 1,500 ms estimated slow-sample cap. All
observations from both cohorts will be kept separately. The question is whether
the newest-at-128 regression reproduces; there is no source tuning in this check.

[Stability run 40642038057](https://github.com/Jagalite/illiquid/actions/runs/40642038057)
is pending. Native macOS qualification of the revised production source is also
pending. The research is not yet a claim of improved whole-player performance.
