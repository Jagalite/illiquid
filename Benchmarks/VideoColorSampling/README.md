# Video color sampling performance

The native presentation coordinator samples video colors for the adaptive UI.
Each sampled frame reads a 12-by-8 grid. The original implementation queries
CoreVideo's base addresses and row strides again at every grid point: 192
layout queries for BGRA, or 480 for the supported bi-planar YCbCr formats.

The candidate resolves the layout once inside the existing read-only buffer
lock, then samples the same coordinates with the same color arithmetic. This
reduces those queries to two for BGRA and five for bi-planar buffers. Pointers
remain local to that call. The next frame reads its own format, strides, matrix,
and addresses.

## Reproduce

Requirements: macOS 26, Xcode 26.6 (or a compatible Swift 6.1+ toolchain), Python 3,
and a complete Git checkout containing baseline commit
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`.

```sh
python3 Benchmarks/VideoColorSampling/run.py --output /tmp/video-color-sampling
```

The output directory must be new. The default run executes baseline and candidate
tests in debug and release, compares full differential receipts, and measures
eight paired rounds. To run only the correctness checks:

```sh
python3 Benchmarks/VideoColorSampling/run.py --tests-only \
  --output /tmp/video-color-sampling-tests
```

Use the repository's Kyoto queue for builds when it is available:

```sh
python3 /Volumes/seed1/Projects/kyoto/kyoto.py submit -- \
  python3 Benchmarks/VideoColorSampling/run.py --output /tmp/video-color-sampling
```

The hosted workflow records Kyoto's absence before building directly. Builds
are serialized and use isolated output directories.

## Source and correctness boundary

Both variants compile complete production files. The only differing production
input is `VideoFrameColorSampler.swift`: baseline bytes come from the pinned Git
commit, and candidate bytes come from the checkout. The shared
`VideoColorSample.swift` and `PiPVideoMapping.swift` must match their baseline
bytes. The benchmark uses real CoreVideo pixel buffers and the actual
Foundation, CoreGraphics, and CoreVideo frameworks.

The isolated SwiftPM packages run the existing sampler tests and the new layout
regressions against both variants in debug and release. They exercise throttling,
smoothing, scene cuts, color matrices, all five supported pixel formats, padded
rows, small and non-grid-aligned dimensions, and changing buffer layouts.

Before timing, the driver emits complete sampled color bit patterns for
deterministic pixel buffers. The runner compares these full records, including
nil outputs, rather than relying on a checksum alone. Full receipts, their
hashes, test logs, sources, exact commands, compiler versions, and binary hashes
are retained in the run output.

## Timing method

The core and native production sources are compiled into separate optimized
dynamic modules. A separately compiled driver calls the native module through
`@testable import`; cross-module optimization is disabled. This prevents the
driver from seeing and hoisting the production sampling body.

Fixtures and warm-up are outside each timed interval. Sampling workloads measure
the complete `sample` operation, including locking, metadata lookup, allocation
of the output array, and all 96 color calculations. The driver rotates among
buffers and consumes returned colors. A throttled-call control covers the
early-return path of `sampleIfNeeded`.

Calibration chooses the same iteration count for both variants of each workload,
targeting at least 100 ms for the faster variant. Eight fresh-process pairs
alternate baseline-first and candidate-first order. Raw measurements and
per-pair ratios are retained; timings do not impose a percentage-based CI gate.

## Scope of the result

This measures the synchronous color-sampling component on the recorded runner.
The default sampler admits at most four samples per second while enabled.
A component speedup therefore represents a small absolute CPU saving; it does
not establish an improvement in decode throughput, whole-player CPU, energy,
frame pacing, or visible playback. Hosted component validation does not replace
physical-device playback QA.
