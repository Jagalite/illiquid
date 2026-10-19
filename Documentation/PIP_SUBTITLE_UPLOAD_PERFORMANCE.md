# PiP subtitle upload reuse

## Question and scope

Can Picture in Picture avoid uploading an unchanged caption on every video
frame while preserving the caption drawn into each output frame?

The baseline is `68274d1b09dcc866296321a5a8858efc297c4f19`. This investigation
starts after the earlier performance PRs were integrated. It addresses the
PiP GPU upload stage, separately from subtitle rasterization, CPU atlas packing,
and the main-window subtitle overlay.

The original `PiPSubtitleCompositor.compose` already retained its
`ASSPreparedSubtitleFrame` when the subtitle pipeline reported unchanged content.
However, `encodeSubtitles` still called `MTLTexture.replace`, rebuilt six vertices
per quad, and copied the vertices into its Metal buffer on every visible frame.
Those operations depended entirely on the retained prepared caption and retained
texture dimensions.

## Change

`PiPSubtitleUploadCache` owns the same one texture and one vertex buffer previously
owned directly by the compositor. Its upload and vertex-generation code was moved
without changing the miss-path algorithm. A clean cache returns those resources
without another texture write, vertex-array construction, or vertex-buffer copy.

The `preparedSubtitleFrame` property observer invalidates the upload cache whenever
the prepared frame is assigned. This includes nil and empty frames, changed text
or bitmap captions, changes to geometry, and source or pipeline revisions. A
pipeline rebind also releases the old GPU resources through `retireSource`.
Failed resource preparation leaves the cache dirty for the next attempt.

Every output video frame still receives its subtitle draw. The current canvas
viewport, target format, SDR/HDR render pipeline, and HDR primaries are bound each
time. Video conversion, output pool limits, frame scheduling, libass cadence,
subtitle memory budgets, and presentation timing are unchanged.

The helper retains no prepared-frame pixels or quads; it uses the compositor's
existing prepared-frame snapshot. The GPU resource capacities follow the previous
allocation rules. This is a reduction in repeated work and requested upload
traffic, not a demonstrated reduction in process footprint.

## Correctness and lifetime

The helper is confined to the compositor's work queue. Production schedules the
next composition after the previous GPU completion, preserving the existing
single-buffer ownership contract. No asynchronous writes or additional frames
in flight are introduced. Tests that use `composedPixelBufferForTesting` await
each GPU completion because that direct seam bypasses production scheduling.

Texture dimensions still determine normalized UV coordinates. Growth, pixel
format changes, and any new prepared caption rebuild the vertices. Smaller
captions use the actual retained texture dimensions, as before. An unchanged
caption may reuse uploads across stop/start while its resources remain valid.

The new native regression suite checks tightly packed output BGRA bytes, excluding
Core Video row padding, together with successful upload counters:

- static bitmap captions at repeated and advancing timestamps;
- changed bitmap pixels and moved quads at the same timestamp and dimensions;
- cue expiry, explicit clears, and rejected old-generation packets;
- external text subtitles off and on at the same timestamp;
- backward seeking to an earlier text cue;
- rebinding an already-rendered pipeline, unbinding, and rebinding again;
- display-size and crop changes;
- static ASS captions and moving ASS captions.

Existing native suites additionally cover PiP reentry, buffer-pool backpressure,
NV12 range and matrix, ten-bit output, HDR, premultiplied bitmap blending, and
subtitle compositor consumers.

## Measurement method

The standalone benchmark uses actual Metal resources on macOS. The candidate is
the complete production upload helper. The baseline adapter mechanically extracts
the original upload block and vertex code at the pinned commit. Both use the
production prepared-frame declarations; source hashes and extraction receipts
are retained. The benchmark does not substitute a model for `MTLTexture.replace`.

Correctness verification is separate from timed loops. It reads actual texture
bytes and vertex-buffer bytes and compares baseline and candidate output. The
native integration suite exercises the complete compositor and subtitle pipeline.
Timed component runs isolate upload and vertex preparation; rendering, decoding,
libass rasterization, and full application playback are outside that interval.

The workload matrix includes multiple atlas sizes, R8 text and BGRA bitmap
formats, unchanged captions, and a control with changed content every frame.
Warmup and calibration are excluded from accepted measurements. Baseline and
candidate run in balanced process order. Measurements are normalized per call,
with raw observations retained rather than a fixed timing threshold on shared CI.

Successful upload metrics report requested active texture bytes and vertex-copy
bytes. They are not physical DRAM traffic, RSS, live GPU allocation size, or energy.
The compositor counters record completed texture/vertex upload pairs; partial
work before an allocation failure is outside those successful-operation counts.

## Evidence and result

Native benchmark and integration qualification are pending. This section will
be replaced with the measured results and exact CI/source receipts before the
research is presented as successful.

## Reproduction

See [the benchmark README](../Benchmarks/PiPSubtitleUpload/README.md) and
[the native CI workflow](../.github/workflows/pip-subtitle-upload-performance.yml).

The relevant production files are
[the compositor](../Sources/IlliquidNativePlayback/Presentation/PiPSubtitleCompositor.swift)
and [the upload cache](../Sources/IlliquidNativePlayback/Presentation/PiPSubtitleUploadCache.swift).
The regression suite is
[PiPSubtitleUploadReuseTests](../Tests/IlliquidNativePlaybackTests/PiPSubtitleUploadReuseTests.swift).
