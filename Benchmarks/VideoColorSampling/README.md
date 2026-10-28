# Video color sampling

## Question and implementation

`VideoFrameColorSampler` samples a 12 × 8 color grid for the adaptive player UI.
The baseline asks CoreVideo for the same plane addresses and row strides at
each of those 96 points. The candidate captures a call-local layout once after
locking the pixel buffer, then uses that layout for the existing sample loop.

For BGRA, the affected address/stride queries fall from 192 to 2 per grid. For
8-bit and 10-bit bi-planar buffers, the plane-count/address/stride queries fall
from 480 to 5. These counts exclude unchanged common buffer queries, attachment
lookup, and locking. There is no layout cache between calls, and every pointer
is used before the existing deferred unlock. Coordinates, color conversion,
range handling, sample ownership, smoothing, and publication rules are preserved.

The production caller normally samples at most four times per second. A faster
component would therefore save a small absolute amount of work. This experiment
does not establish lower whole-player CPU, power use, frame drops, or UI latency.

## Reproduce

Native macOS 26 and Swift are required because this experiment uses real
CoreVideo/IOSurface-backed buffers. It does not need FFmpeg or libass for the
isolated comparison.

```sh
export DEVELOPER_DIR=/Applications/Xcode_26.6.app/Contents/Developer
python3 Benchmarks/VideoColorSampling/run.py \
  --output /tmp/illiquid-video-color-sampling --pairs 8 --target-ms 200
```

The output directory must be new or empty. The pinned baseline is
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`; it must be present in the local Git
repository. `--baseline` can select another explicit comparison revision.
`--tests-only` compiles and verifies without timing; repeat `--case NAME` to
restrict timing while retaining all output verification.

Compiler invocations use the shared Kyoto queue when it is available. Otherwise
the runner explains its absence and compiles serially in isolated directories.

## Method

The runner stages complete, unmodified source files from the baseline and the
working tree. Both variants compile the actual `VideoColorSample.swift` core
module, `PiPVideoMapping.swift`, and `VideoFrameColorSampler.swift`. The shared
core and mapping sources must be identical between variants. There are no
replacement CoreVideo functions or rewritten sampler extracts.

Before timing, debug and optimized binaries must emit identical complete color
component bit patterns and stateful publication traces. Fixtures cover all five
supported formats, 1080p, padded and tiny buffers, missing/601/709/2020 matrix
attachments, spatially varying pixels and chroma, mutations, and format changes.
Independent black/white expectations, an unsupported-format check, and a reset
check complement differential parity. The application test suite adds spatial
reference expectations and exercises throttling, smoothing, and UI consumers.

Timing uses optimized builds and fresh processes. Each observation creates and
fills two buffers before warming and timing; buffer creation and filling are
excluded. The timed loop alternates the buffers, calls the production sampler,
consumes the returned color bits in a checksum, and includes bounded
autorelease-pool cleanup. Raw-sample cases cover all five formats at three
sizes. Additional cases cover unsupported input, accepted four-hertz sample
calls including state/publication work, and already-throttled calls.

Both variants receive the same iteration count. Calibration targets at least
200 ms in the faster variant with a 1.5× margin, capped at 100 million calls.
Eight pairs alternate baseline/candidate process order. The runner records
wall and process CPU time, every observation, paired changes, ranges, duration
shortfalls, and matching output checksums. No timing observations are discarded.
Results include checksum/loop overhead; they are not isolated CoreVideo getter
latencies. Buffers are warmed synthetic fixtures, not decoded playback captures.

## Qualification and evidence

The `Video color sampling performance` workflow runs this native comparison on
the research branch before a PR is opened. A separate job installs the pinned
native SDK, builds the full application/test graph in release mode, and runs
the sampler, PiP mapping, adaptive color/legibility, sampling-gate, and color
publication regressions. It does not claim interactive or end-to-end playback
qualification.

The workflow retains source/compiler receipts, exact output traces, raw timing
observations, calibration, summaries, command logs, and native test receipts.
Measured results and durable evidence will be recorded here after qualification.
