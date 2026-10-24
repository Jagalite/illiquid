# Video decoder scratch-frame lifetime

## Finding and change

`VideoDecoder.receiveFrames` reuses one FFmpeg `AVFrame`. The original loop
unreferenced that frame immediately before its next `avcodec_receive_frame`
call. The continuation check ran first, and output delivery could throw before
the loop returned to its start. Both paths could therefore leave the last
decoded frame referenced by the decoder after the operation returned.

The candidate adds one function-scope `defer { av_frame_unref(frame) }` after
the decoder pointers are obtained. The existing loop and error handling remain
unchanged. Scratch storage is cleared on successful return, cancellation,
consumer error, output-admission failure, and errors during output conversion.
No cache, synchronization, public API, or output-buffer policy is added.

This is a bounded lifetime correction, not unbounded accumulation. Successful
continuous decoding already clears the scratch reference at the next iteration.
The affected decoder may retain one source frame until another receive call,
decoder replacement, or destruction. `flush()` in the original implementation
flushes codec state and output pools but does not clear this external scratch
frame.

The production `MediaSession` video loop catches
`SoftwarePixelBufferPoolError.cancelled` and continues with the retained
decoder. That is an ownership path in which prompt release is useful. The
thumbnail generator, by contrast, drops its context on propagated errors and
cancellation; this report does not claim persistent thumbnail retention after
those paths. The frequency and duration of this condition in interactive
playback have not been measured.

## Why output stays valid

The scratch frame is not the sole owner of delivered output or intentional
decoder history:

| Object | Independent ownership |
| --- | --- |
| VideoToolbox output | `makeFrame` retains the `CVPixelBuffer`. |
| BGRA and planar software output | Conversion copies into separately owned CoreVideo buffers. |
| HDR and geometry metadata | Value fields, owned `Data`, and CoreVideo attachments retain their contents. |
| BWDIF input history | Submission uses `AV_BUFFERSRC_FLAG_KEEP_REF`. |
| BWDIF output frame | The filter already clears its own scratch output with a defer. |
| Thumbnail seek fallback | `SeekPrerollFallback` owns an `av_frame_clone` reference. |

The fix clears none of the filter graph, codec reference pictures, seek fallback,
output pools, renderer buffers, or held output frames. Existing generation and
error-propagation behavior is preserved.

FFmpeg documents that `av_frame_unref` releases a frame's buffer references and
resets its fields; cloned frames retain references to the same backing data.
Its `AVBuffer` contract frees the backing allocation when the last reference is
released. These contracts support the ownership boundary tested here:

- [FFmpeg AVFrame API](https://ffmpeg.org/doxygen/8.0/group__lavu__frame.html)
- [FFmpeg AVBuffer API](https://ffmpeg.org/doxygen/8.0/group__lavu__buffer.html)
- Pinned source: `DependencySources/archives/ffmpeg-8.1.2.tar.xz`,
  `libavcodec/rawdec.c`, `libavcodec/decode.c`, and `libavutil/buffer.c`.

## Experiment

The reproducible experiment uses the complete native SwiftPM package and the
repository's pinned FFmpeg/CoreVideo environment. The baseline is
`6f70cd2446fc6ef38d4e5a0fbf96f91b2234e635`. Both variants compile the identical
scratch-lifetime helper and measurement harness; the only production-source
difference is the four-line `receiveFrames` addition. The candidate also builds
the added EOF regression, which is not selected during measurement invocations.

Synthetic raw BGRA packets expose the native source allocation without adding
a production diagnostic API. The real FFmpeg rawvideo decoder references the
packet's `AVBuffer` in its decoded frame. A custom free callback records actual
deallocation. While the caller retains the packet, an extra scratch owner is
visible through the native reference count. After the packet-owning helper
returns, the decoder and any output remain alive while the probe observes
whether the source allocation has been freed.

The experiment separately observes the packet-release, flush, and decoder-
destruction boundaries. Full active-pixel hashes, metadata, output counts, and
timestamps must agree across revisions and across lifetime boundaries.
Each normal control checks counts and the timestamp sum across all 100 calls;
its pixel hashes and metadata describe the last held output frame.

Four interrupted paths (consumer error, cancellation after output, denied
software-output reservation, and timestamp-consumer error) run at 64×48,
1920×1080, and 3840×2160. Two normal-decode controls run at 64×48 and
1920×1080, with 100 calls per process. Four alternating AB/BA pairs produce
112 separately executed observations. Build probes are excluded.

The reported payload byte count is the exact requested source pixel payload.
Storage bytes additionally include FFmpeg's required zero padding. The callback
demonstrates destruction of that allocation; it does not measure allocator
rounding, RSS, physical footprint, GPU memory, or total process allocation.
Compressed codecs and filters can legitimately hold other references to a
frame, so removing the scratch reference does not imply that every real media
frame's backing bytes are immediately freed.

## Native results

The [native release run](https://github.com/Jagalite/illiquid/actions/runs/40101088087)
passed on 24 October 2026. It qualified candidate
`40b8cae2651e643491f82af34f1c4b608e1cbc62` against the pinned baseline above,
on an arm64 macOS 26.6.2 virtual machine with three CPUs and 7 GiB of RAM,
Xcode 26.6, Apple Swift 6.3.3, and macOS SDK 26.5. Both complete application/test
graphs built in release mode. The candidate checkout was clean.

All 112 observations completed, forming 56 matched comparisons across fourteen
workloads. Each of the four interrupted-output paths produced this exact result
at every paired repetition:

| Source dimensions | Original retained pixel payload | Original retained allocation, including padding | Candidate retained allocation |
| --- | ---: | ---: | ---: |
| 64 × 48 | 12,288 bytes | 12,352 bytes | 0 bytes |
| 1920 × 1080 | 8,294,400 bytes | 8,294,464 bytes (7.91 MiB) | 0 bytes |
| 3840 × 2160 | 33,177,600 bytes | 33,177,664 bytes (31.64 MiB) | 0 bytes |

These observations were made after the caller released its input packet while
the decoder and any delivered output remained alive. The original allocation
also survived `flush()` and was released only when the decoder was destroyed.
The candidate released it before the packet-release sample. Each tracked
allocation's free callback ran exactly once by decoder destruction. While the
input packet was still alive, interrupted calls left two buffer references in
the original and one in the candidate, directly identifying the removed owner.

Both normal-decode controls retained zero tracked source bytes in both versions.
All paired output counts, timestamps, captured metadata, and held-pixel hashes
matched. Pixel hashes also remained unchanged across flush and decoder
destruction. The focused native suites passed all seventeen test declarations:
nine scratch-lifetime tests and eight timestamp-discovery tests, executing
nineteen and twenty-six parameterized cases respectively (45 cases total).

### Decode timing controls

Each normal observation contains 100 decode calls; the table reports medians
and the minimum–maximum range across four fresh processes per variant, in
microseconds per call. Timing excludes input construction, hashing, flush, and
decoder destruction. The first output-pool creation is included and amortized
over the 100 calls.

| Normal workload | Original wall time, µs | Candidate wall time, µs | Original CPU time, µs | Candidate CPU time, µs |
| --- | ---: | ---: | ---: | ---: |
| 64 × 48 | 29.11 (27.52–30.23) | 29.95 (28.56–30.20) | 39.23 (37.60–39.71) | 38.38 (37.41–40.10) |
| 1920 × 1080 | 467.44 (327.78–608.38) | 348.88 (284.72–454.30) | 468.92 (328.53–613.57) | 350.35 (285.26–457.50) |

The median paired wall-time change was **+2.53%** for the small control and
**−20.71%** for 1080p; the corresponding CPU changes were −1.24% and −20.76%.
The sample is small, ranges overlap, and the 1080p results vary substantially.
These measurements neither establish a speedup nor rule out a small normal-path
cost from the additional cleanup call. The demonstrated benefit is prompt
release of the otherwise retained source allocation.

### Reviewable evidence

The [completion receipt](../Benchmarks/VideoScratchFrameLifetime/evidence/native/completion.json),
[raw observations](../Benchmarks/VideoScratchFrameLifetime/evidence/native/observations.jsonl),
and [summary](../Benchmarks/VideoScratchFrameLifetime/evidence/native/summary.json)
are committed alongside source, binary, fixture, command, environment, and
regression receipts. The unchanged original compressed evidence bundle contains
all 180 files emitted by the workflow, including build and measurement logs and
archived source snapshots. Its SHA-256 is
`4c6ffd735d04ca0b2f1240e995c687df859d1bd811c157bebbb4e672af4c59bf`;
[provenance](../Benchmarks/VideoScratchFrameLifetime/evidence/native/provenance.json)
identifies the exact native job and bundle format. Build probes are preserved
separately and are excluded from the 112 measured observations.

Follow-up changes add documentation, evidence, and CI integration; the qualified
production code, Swift tests, and paired runner remain unchanged.

## Regression coverage

The focused suite verifies the actual decoder with tracked native source
allocations, including both deinterlacing-disabled and progressive pass-through
configuration. It checks original error identity, exact reference counts,
destruction once, output after reuse/flush/destruction, repeated cancellation,
and intentional fallback references until take or flush.

The generated timestamp suite independently exercises delayed H.264 output,
VFR, nonzero timeline origins, top/bottom-field MPEG-2 BWDIF, repeated seeks,
normal drain, and reuse after cancellation/consumer error. The new EOF regression
requires its single H.264 frame to be emitted during drain, then throws from
that callback and verifies the held pixels and subsequent decoder replay.

These tests do not qualify live rendering, UI responsiveness, playback FPS,
energy consumption, or the prevalence of the interrupted-frame condition.

## Reproduction and scope

See [benchmark instructions](../Benchmarks/VideoScratchFrameLifetime/README.md).
The paired experiment is pinned to the qualified candidate commit. Future
merged-source regression coverage belongs to the frame-step timestamp workflow.

A concurrent [PR #100](https://github.com/Jagalite/illiquid/pull/100) independently
investigates the same scratch-frame lifetime with iteration-scoped cleanup.
This investigation uses function-scoped cleanup, exact source-allocation free
callbacks, output-admission rejection coverage, and explicit fallback and EOF
lifetime tests. The production fixes overlap and should be reviewed as
alternatives; this report does not claim an additional cumulative memory saving
over that PR.
