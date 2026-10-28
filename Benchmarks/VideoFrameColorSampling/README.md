# Video frame color sampling

This experiment compares the actual macOS CoreVideo sampling implementation with
its byte-identical pre-change source at commit
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`.
The baseline file has Git blob
`4ff4ebfd1b23235bf8843ee87eb2b9de4f0af574`.

The candidate resolves plane addresses and byte strides once inside each
successful pixel-buffer lock. It does not cache pointers, dimensions, or color
metadata between calls. Sampling coordinates, conversion arithmetic, publication
thresholds, and the default four-hertz cadence are unchanged.

## Qualified result

The [2026-10-28 native research report](../../Documentation/VIDEO_FRAME_COLOR_SAMPLING_PERFORMANCE.md)
records the measured improvement, absolute impact, correctness checks, and limits.
Paired summaries and all raw observations are committed in
[`evidence/macos-2026-10-28`](evidence/macos-2026-10-28).

## Run

Requires macOS 26 and Xcode with Swift 6.1 or newer. The isolated component
build uses the repository's unmodified sampler, mapping, and color-value source
files with real CoreVideo; it does not need FFmpeg, libass, or a substitute API.

```sh
python3 Benchmarks/VideoFrameColorSampling/run.py \
  --pairs 8 --target-ms 150 --output /tmp/video-frame-color-sampling
```

Use a new output directory for every run. On a machine with the shared Kyoto
queue, submit the entire command through it and inspect the job's show, logs,
and wait results:

```sh
python3 /Volumes/seed1/Projects/kyoto/kyoto.py submit -- \
  env ILLIQUID_SAMPLER_QUEUED=1 \
  python3 Benchmarks/VideoFrameColorSampling/run.py \
  --pairs 8 --target-ms 150 --output /tmp/video-frame-color-sampling
```

The runner reports Kyoto's absence before using serial direct builds on hosted
macOS CI. Its baseline and candidate builds use distinct scratch directories.

## Qualification and measurement

Both variants run the existing sampler tests and independent layout tests in
debug and release. The new tests cover every grid cell, five pixel formats,
padded rows, tiny buffers, 10-bit low-bit noise, reused sampler instances, matrix
attachment removal, and unsupported input.

The benchmark compiles the actual production sources into separate optimized
dynamic libraries and links the same driver to each. Verification compares the
complete sampled-color and temporal output receipts before timing. RGB values
are represented by their exact Double bit patterns.

Every observation runs in a fresh process. Fixtures are allocated and populated
before warmup and timing. A lightweight, varying output checksum is consumed
inside the timed loop. The runner calibrates both variants, uses balanced
baseline/candidate and candidate/baseline ordering, and retains every raw wall
and process CPU measurement. Throttled calls and unsupported formats provide
controls. Timed output checksums must match for every pair.

Outputs include source and binary hashes, host/compiler metadata, test logs,
full verification receipts, calibrations, raw observations, and paired summaries.
The workflow uploads them as an artifact and emits a compact machine-readable
receipt in its logs.

## Scope

These are component measurements on warm CPU-accessible IOSurface buffers.
They do not measure decoding, frame presentation, playback FPS, end-to-end
latency, energy use, or contention with real VideoToolbox/GPU-produced buffers.
The sampler ordinarily runs at most four times per second; report absolute
microseconds saved alongside percentages.
