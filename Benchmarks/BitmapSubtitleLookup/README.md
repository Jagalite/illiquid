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

Validation is pending. The new search preserves direct newest and penultimate
probes and finds a smaller bracket before binary search. The same full workload
matrix and correctness suite will decide whether it is worth proposing.

