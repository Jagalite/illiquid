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

The native Metal component qualification passed on 19 October 2026 at commit
`8f8677024a7c5b852005d51651558ccdfc79ad6b` in
[Actions run 39319056032](https://github.com/Jagalite/illiquid/actions/runs/39319056032).
The measured production helper is unchanged in the subsequent evidence commit;
its SHA-256 is recorded in the source receipt.

The runner was a **macOS VM**: macOS 26.6.2, `VirtualMac2,1`, arm64, Xcode 26.6,
Swift 6.3.3, and the Metal device `Apple Paravirtual device`. These are real
macOS Metal API calls on that environment, not measurements of a named physical
Apple GPU. Absolute timings may differ substantially on physical Macs.

### Unchanged captions

CPU time below is the median per helper call, after the caption's first upload.
Each variant/workload has 14 fresh-process observations.

| Atlas | Baseline CPU, microseconds/call | Reuse CPU, microseconds/call | CPU reduction | Texture bytes requested per reused call, before → after |
| --- | ---: | ---: | ---: | ---: |
| R8, 64 KiB | 3.246 | 0.0433 | 98.67% | 65,536 → 0 |
| R8, 1 MiB | 36.927 | 0.0438 | 99.88% | 1,048,576 → 0 |
| R8, 4 MiB | 174.626 | 0.0473 | 99.97% | 4,194,304 → 0 |
| BGRA, 1 MiB | 35.157 | 0.0430 | 99.88% | 1,048,576 → 0 |

All unchanged-caption observations recorded zero additional candidate texture
uploads and vertex copies. The baseline performed one of each on every call.
The eight-quad input also avoided its repeated 1,536-byte vertex copy. The
baseline and candidate timing ranges did not overlap in any unchanged workload.

This supports reusing the existing GPU resources while a caption stays unchanged.
The absolute component savings matter more than the large percentages: for
example, the 1 MiB R8 case saves about 36.9 microseconds per reused call on this
runner. This does not make the player, a full frame, or its GPU draw 99.88% faster.

### Changing-caption controls

Changed captions still need their texture upload and vertex rebuild. They are
included to expose miss-path costs, with the same alternating pixels and geometry
for both variants. CPU ranges below are the minimum and maximum fresh-process
observations, not confidence intervals.

| Atlas | Baseline CPU median (range), microseconds/call | Candidate CPU median (range), microseconds/call | CPU median change | Wall median change |
| --- | ---: | ---: | ---: | ---: |
| R8, 64 KiB | 3.248 (2.837–5.041) | 3.196 (2.593–3.556) | −1.62% | −5.92% |
| R8, 1 MiB | 38.073 (25.800–46.478) | 39.497 (33.992–57.129) | +3.74% | +3.34% |
| R8, 4 MiB | 165.819 (130.251–214.540) | 167.173 (131.266–231.393) | +0.82% | +6.90% |
| BGRA, 1 MiB | 36.746 (31.739–51.124) | 40.127 (31.895–49.633) | +9.20% | −2.16% |

These controls show no consistent benefit. All ranges overlap. In particular,
the BGRA control's CPU median increased 9.20%, while its wall median decreased
2.16%; the median of its individual paired CPU ratios is 1.013. The cohort is
variable, and it does not establish that the changed-caption path is free of
regressions. The benefit being accepted is the avoided work on unchanged frames;
no speedup is claimed for animated or otherwise changing captions.

### Validation and retained evidence

The component run completed all 224 accepted observations in balanced order.
The shortest timed process CPU interval was 46.109 ms; calibration and warmup
are excluded. All 18 correctness transitions matched, including 17 actual
GPU draws per variant with exact texture, vertex, and rendered-output equality.
Every timed observation also passed its post-timing byte and counter checks.
An independent audit recomputed the cohort's summaries and checked source and
binary hashes against the receipt.

The [native regression job](https://github.com/Jagalite/illiquid/actions/runs/39319056032/job/118288020817)
also passed after building the complete app/test graph in release configuration.
Swift Testing reported 59 passing tests across five suites. All eight new upload
tests executed and passed, including their exact pixel and upload-count checks.
Two existing optional-fixture tests returned early because their media fixtures
were not configured: `heavyAnimatedFixtureCostsAreRecorded` and
`mediaSessionMirrorsEmbeddedPacketsAndSeekInvalidationToBothPipelines`. Their
fixture bodies are not claimed as exercised. The
[original native test log](../Benchmarks/PiPSubtitleUpload/results/2026-10-19/native-tests.log)
is retained.

Before opening the PR, the branch also incorporates main at
`33fff16155c3472960f88e04c72dfdfdefd56dcf`. The measured upload baseline, prepared
frame declarations, subtitle pipeline, and shaders did not change between the
research baseline and that main revision. The repository's normal PR checks
qualify the integrated branch, separately from the pinned measurement above.

The [retained evidence directory](../Benchmarks/PiPSubtitleUpload/results/2026-10-19/)
contains the original raw observations, calibration, environment, source and
binary hashes, correctness receipts, full command journal, and summary. The
[CI receipt](../Benchmarks/PiPSubtitleUpload/results/2026-10-19/ci-receipt.json)
links the run and records the downloaded artifact's verified SHA-256 plus hashes
of the retained files. Generated binaries and module caches remain in the
Actions artifact rather than being checked into the repository.

The timed interval covers the upload helper and accumulation of returned counters.
It excludes the surrounding compositor's synchronization and metric updates,
packing, video conversion, actual draw encoding/completion, and presentation.
Full-player CPU, playback smoothness, energy, process footprint, physical DRAM
traffic, and performance on physical hardware remain unmeasured.

## Reproduction

See [the benchmark README](../Benchmarks/PiPSubtitleUpload/README.md) and
[the native CI workflow](../.github/workflows/pip-subtitle-upload-performance.yml).

The relevant production files are
[the compositor](../Sources/IlliquidNativePlayback/Presentation/PiPSubtitleCompositor.swift)
and [the upload cache](../Sources/IlliquidNativePlayback/Presentation/PiPSubtitleUploadCache.swift).
The regression suite is
[PiPSubtitleUploadReuseTests](../Tests/IlliquidNativePlaybackTests/PiPSubtitleUploadReuseTests.swift).
