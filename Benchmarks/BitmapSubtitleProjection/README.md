# Bitmap subtitle region projection

`NativeBitmapSubtitleComposition.renderedRegions(in:forcedOnly:)` transforms
bitmap subtitle regions into display coordinates. The baseline first builds a
filtered region array even when `forcedOnly` is false and every region passes.
The candidate shares the existing input array in that case and maps it directly.
Forced-only selection still filters before the same projection arithmetic.

The production change is two lines in `BitmapSubtitleTimeline.swift`. It leaves
timeline lookup/insertion, pixel bytes, region order, coordinate arithmetic,
stride, bitmap size, color flags, and memory-lease sharing unchanged.

## Reproduce

Requires Swift 6.1 or newer and Python 3.11 or newer. Run builds through Kyoto
when available, as required by `AGENTS.md`. Otherwise explain that limitation
and use serial builds in an isolated checkout. Run one timing campaign at a time.

```sh
python3 Benchmarks/BitmapSubtitleProjection/run.py \
  --pairs 10 --target-ms 150 --output /tmp/bitmap-subtitle-projection
```

The output directory must be new or empty. `--mode test` runs both production
variants' unit tests in debug and release, builds optimized modules, and checks
complete input/output parity without timing. `--mode benchmark` skips unit tests
but still checks complete output parity before measuring. `SWIFTC` and `SWIFT`
select another toolchain. Caches, temporary files, and build products stay under
the output directory; `HOME` is unchanged.

## Sources and correctness

The frozen baseline is the full timeline source from
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`. The baseline and shared dependency
hashes are pinned in `baseline/manifest.json`; the runner rejects mismatches.
Each variant compiles the complete production timeline and memory-budget files
and the exact `ASSRenderedRegion` declaration extracted from `LibassContext`.
No behavior is mocked. Native builds retain the original imports. On Linux,
only `import CoreGraphics` is removed because real Foundation geometry types
are available there; Linux execution does not establish native macOS timing.

The production module is optimized separately from the driver, with
`-enable-testing` exposing existing internal APIs. There is no cross-module
optimization or copied production projection implementation in the driver.
The final source, driver, tests, compiler, and binary hashes are retained.

The ten new regression functions cover exact pixel bytes/order, ordinary and
forced selection, anisotropic scaling and translation, fractional dimensions,
original bitmap size and stride, empty results, invalid canvas dimensions,
existing nonfinite geometry behavior, repeated calls, value-copy independence,
and shared lease lifetime. Existing timeline ordering and budget accounting
tests run in the same isolated package against both variants in debug/release.

The optimized driver compares 208 complete input/output fixtures: 26 scenarios,
four viewports, and present/absent leases. Receipts include complete bitmap
bytes, floating-point bit patterns, canvas/viewport geometry, forced flags,
output fields, and lease-sharing observations. Timed processes also perform
untimed field/lease checks and emit consumed result checksums; every pair must
agree on its workload, count, warm-up, and output checksum.

## Measurements and decision

Twenty-six timing workloads cover 0, 1, 2, 4, 16, and 64 input regions, with
ordinary selection and forced-only all/some/none patterns, plus zero/NaN canvas
controls. Small ordinary region counts are the primary workloads; 16/64-region
cases are scaling probes, not claims about typical subtitle complexity.

The timed boundary includes complete projection calls, consuming representative
returned fields, and releasing the output arrays. Fixture/pixel/lease creation,
full-output serialization, and correctness checks are outside timing. No pixel
decoding, GPU upload, rendering, or pipeline locking is timed.

Calibration targets at least 90% of the requested process CPU interval in both
variants, subject to 12 attempts and ten million iterations. Achieved intervals
and stopping reasons are recorded. Both variants then use the same fixed count
for each workload in ten fresh-process AB/BA pairs, interleaved across rounds.
All probes and observations are retained. CPU and wall-time summaries report
absolute medians, paired ratios, and faster-pair counts; no outliers are removed.

The research acceptance criterion is at least a 10% median paired CPU reduction
with at least 8/10 faster pairs for ordinary 1/2/4-region projection, exact output
parity, and no repeatable material regression in forced-only/empty controls.
Timing is evidence for review, not a noisy percentage-based CI gate. Native
qualification independently repeats the comparison and builds the full app
graph with bitmap/Picture-in-Picture integration tests.

`SubtitlePipeline` caches unchanged bitmap output. This function runs under its
lock when the bitmap event, timeline revision, or display geometry changes.
Results therefore describe changed-region projection, not an improvement on
every video frame. Absolute savings, small controls, and platform scope matter;
no whole-player CPU, frame-rate, resident-memory, or battery claim is made.

## Evidence

The runner retains every command and log, complete receipts, source and binary
hashes, compiler/host metadata, calibration probes, and raw measurements.
Native artifacts are `bitmap-subtitle-projection-native` and
`bitmap-subtitle-projection-integration`. Results and the acceptance decision
will be recorded after qualification.
