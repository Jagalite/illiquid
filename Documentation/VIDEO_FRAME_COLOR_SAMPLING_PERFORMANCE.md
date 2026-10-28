# Video frame color sampling performance

## Result

Resolving a pixel buffer's plane layout once per sampling call reduces measured
process CPU time by **39.4–46.2% for BGRA** and **64.8–69.2% for bi-planar YUV**
across the fifteen supported-format workloads on the qualified macOS runner.
All eight paired comparisons improved in both process CPU and wall time for
every supported workload (120 pairs total). The baseline and candidate produce
identical verification receipts.

This is a small component optimization. The difference between the per-variant
CPU medians is **2.31–6.84 microseconds per sample**. At the default maximum
cadence of four successful samples per second, that corresponds to approximately
**9.25–27.35 microseconds of CPU time per second**, or **0.00092–0.00273% of one
CPU core**. This arithmetic extrapolation assumes the measured warm-buffer cost;
it is not a playback or energy measurement.

## Change and hypothesis

`VideoFrameColorSampler.sample()` samples a 12 × 8 grid for adaptive UI colors.
The original implementation resolves CoreVideo plane metadata again for each
of the 96 grid points. The candidate creates a call-local `PixelLayout` after
the existing successful read-only lock, then reuses its addresses and byte
strides while that buffer remains locked.

A source-level count of the relevant CoreVideo getter calls falls from 192 to 2
for BGRA, and from 480 to 5 for supported bi-planar formats. These counts exclude
unchanged dimension, format, attachment, and lock calls; they are static counts,
not profiler measurements. The refactor also changes dispatch and removes
per-point optional handling, so the timings measure the complete refactor rather
than isolating one getter's cost.

Addresses and strides remain local to the locked call. Each buffer's layout and
matrix metadata are read afresh. Grid coordinates, channel conversion arithmetic,
10-bit shifts, color ranges, smoothing, scene-cut detection, publication
thresholds, reset behavior, and the default cadence are preserved.

## Qualified sources and environment

- Baseline commit: [`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`](https://github.com/Jagalite/illiquid/commit/ea2ff568237e2667f7b1aeee67b11a44ebe95b72).
- Baseline sampler Git blob: `4ff4ebfd1b23235bf8843ee87eb2b9de4f0af574`; the runner checks it before building.
- Measured candidate commit: [`898c52afcb9c5777320529962efbdae39f20fe01`](https://github.com/Jagalite/illiquid/commit/898c52afcb9c5777320529962efbdae39f20fe01).
- Successful native run: [40636025118](https://github.com/Jagalite/illiquid/actions/runs/40636025118), job `122643073861`, 2026-10-28 05:39:06–05:42:16 UTC.
- Host: GitHub-hosted `macos-26-arm64`, macOS 26.6.2 (25G83), Apple M1 (Virtual), arm64.
- Toolchain: Xcode 26.6, Apple Swift 6.3.3; target `arm64-apple-macosx26.0`.
- Clean measured worktree. The source hashes are retained in the [qualification receipt](../Benchmarks/VideoFrameColorSampling/evidence/macos-2026-10-28/qualification.json).
- Kyoto was absent on this host; the runner reported that before serial direct builds.

The final evidence/documentation commit does not alter the measured production,
test, driver, or runner sources. It removes the temporary research-branch push
trigger; pull-request and manual workflow triggers remain.

## Method

Both variants compile the repository's actual `VideoColorSample.swift`,
`PiPVideoMapping.swift`, and corresponding sampler source. Separate optimized
dynamic libraries are linked to the same driver with Swift 6,
`-O -whole-module-optimization -warnings-as-errors`. This uses native CoreVideo,
without FFmpeg, libass, or substituted pixel-buffer APIs.

For each of seventeen workloads, the runner uses eight fresh-process baseline/
candidate pairs with balanced AB/BA ordering. Both variants use the same
iteration count within each workload. Calibration targets 150 ms for the faster
variant and caps projected slower runs at 1.5 seconds; actual durations are
retained. Calibration is an estimate, not a guaranteed observation duration.

Two heterogeneous IOSurface-backed buffers are allocated and filled before
each process's warmup and timed loop. Up to 512 calls warm the sampler.
Allocation, fixture filling, and full output verification are outside timing.
Each timed call consumes a varying output cell's RGB bit patterns in a small
checksum; the same checksum work applies to both variants. Timed sampling
includes buffer locking, output allocation, and conversion. Supported workloads
must produce a real 12 × 8 sample during verification and non-nil samples on
every timed and warmup call. Every pair's output checksums must match.

Wall time uses `DispatchTime`; process CPU time uses
`CLOCK_PROCESS_CPUTIME_ID`. The raw observations retain both timings, iteration
counts, non-nil sample counts, warmup counts/checksums, order, and output
checksums. All 272 observations are preserved.

## Supported-format measurements

CPU columns are each variant's median microseconds per sampling call. Reduction
columns are the median of eight paired percentage reductions; they are not the
ratio of the two separately computed CPU medians. “Faster pairs” applies to both
CPU and wall time.

| Workload | Baseline CPU µs | Candidate CPU µs | Paired CPU reduction | Paired wall reduction | Faster pairs |
| --- | ---: | ---: | ---: | ---: | ---: |
| `bgra-1080p` | 5.778 | 3.467 | 39.4% | 39.3% | 8/8 |
| `bgra-4k` | 6.109 | 3.037 | 46.2% | 46.0% | 8/8 |
| `bgra-padded` | 5.563 | 3.229 | 43.7% | 43.1% | 8/8 |
| `420v-1080p` | 10.256 | 3.419 | 67.0% | 67.0% | 8/8 |
| `420v-4k` | 9.749 | 3.209 | 66.0% | 66.0% | 8/8 |
| `420v-padded` | 8.033 | 2.628 | 67.2% | 67.2% | 8/8 |
| `420f-1080p` | 7.884 | 2.471 | 69.2% | 69.2% | 8/8 |
| `420f-4k` | 7.983 | 2.598 | 66.8% | 66.8% | 8/8 |
| `420f-padded` | 8.205 | 2.534 | 68.1% | 68.2% | 8/8 |
| `x420-1080p` | 7.346 | 2.526 | 66.2% | 66.2% | 8/8 |
| `x420-4k` | 8.857 | 3.293 | 64.8% | 62.0% | 8/8 |
| `x420-padded` | 7.222 | 2.440 | 66.6% | 66.6% | 8/8 |
| `xf20-1080p` | 7.955 | 2.492 | 67.5% | 68.4% | 8/8 |
| `xf20-4k` | 7.597 | 2.553 | 66.1% | 66.1% | 8/8 |
| `xf20-padded` | 8.414 | 2.738 | 68.6% | 68.7% | 8/8 |

`1080p` is 1920 × 1080; `4k` is 3840 × 2160; `padded` is 26 × 18 with a
128-byte requested row alignment. Formats are BGRA, `420v` (8-bit video range),
`420f` (8-bit full range), `x420` (10-bit video range), and `xf20` (10-bit full
range). Each plane's actual stride is used.

## Controls

The unsupported ARGB path returned nil on every measured call. Its CPU medians
were 1.380 → 0.955 µs, with a median paired reduction of 31.5%. This path changes:
the new layout check rejects it before matrix lookup and output-array reserve.
It is reported separately from successful sampling.

The pre-primed throttle control returned nil on every timed call. Its CPU
medians were 19.842 → 20.215 ns, while the median paired change was −0.21%
(5/8 pairs faster). The differently computed summaries and mixed pair results
do not establish an improvement for this control. No throttle-path speedup is
claimed.

## Correctness qualification

All **11 component tests passed in each of four runs**: baseline debug, baseline
release, candidate debug, and candidate release, with warnings treated as errors.
These runs include the seven existing sampler test functions and four new layout
test functions (one parameterized over all five formats).

The independent layout tests check every grid cell against a scalar oracle,
including tiny buffers, padded rows, heterogeneous luma/chroma, noisy unused
10-bit low bits, reused samplers, changed buffer dimensions/formats, removed
matrix attachments, and unsupported input. Existing tests cover temporal
smoothing, throttling, scene cuts, meaningful-change suppression, and colors.

Before timing, both variants produce the same full receipt for 150 non-nil
supported direct samples, ten unsupported nil samples, and 46 temporal records.
The temporal sequence exercises throttling, backwards timestamps, reset,
smoothing, publication suppression, and scene cuts. Direct fixtures change
matrix attachments (unspecified, BT.601, BT.709, BT.2020, then removed) on reused
buffers. Every sampled RGB Double bit pattern, dimension, stride, and nil result
is compared. Both serialized verification receipts have SHA-256:

```
2a3972639b65c39bb73fdbaf28681f0e147d8c7c68ce60c13e3adaab24cf7473
```

This qualifies the isolated native component. The full application, FFmpeg
integration, and playback UI were not built or exercised by this workflow.

## Evidence and reproduction

The permanent evidence directory contains:

- [Paired summaries](../Benchmarks/VideoFrameColorSampling/evidence/macos-2026-10-28/summary.json).
- [All 272 raw observations](../Benchmarks/VideoFrameColorSampling/evidence/macos-2026-10-28/observations.json).
- [Verification hashes](../Benchmarks/VideoFrameColorSampling/evidence/macos-2026-10-28/verification.json).
- [Compact qualification manifest](../Benchmarks/VideoFrameColorSampling/evidence/macos-2026-10-28/qualification.json).
- [Run and artifact provenance](../Benchmarks/VideoFrameColorSampling/evidence/macos-2026-10-28/provenance.json).

These are the decoded machine-readable receipts emitted by the successful job.
The compact qualification receipt omits the full command list and binary/log
hash list. The [workflow artifact](https://github.com/Jagalite/illiquid/actions/runs/40636025118/artifacts/12794429295)
also contains the complete manifest, source snapshots, full verification
receipts, calibrations, and command logs; that artifact has a 30-day retention
period. The committed receipts remain available independently.

See [the benchmark README](../Benchmarks/VideoFrameColorSampling/README.md) for
the reproduction command and Kyoto queue instructions. Use a new output
directory for each run.

## Limits

The measurements describe one virtualized Apple Silicon runner with warm,
CPU-accessible IOSurface buffers. Pairing and alternating order reduce ordering
bias but do not establish a confidence interval or generalize the result to
every Mac. Some individual pair values vary substantially, especially for the
nanosecond-scale throttle control; raw values are retained.

The experiment does not measure decoding, presentation, playback FPS,
end-to-end latency, energy use, cold-buffer behavior, or synchronization with
real VideoToolbox/GPU-produced buffers. The default four-hertz sampling cadence
makes the absolute expected CPU saving small. The production change is justified
as a bounded component improvement with identical tested output.
