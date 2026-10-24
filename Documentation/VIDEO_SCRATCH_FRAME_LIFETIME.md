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
`6f70cd2446fc6ef38d4e5a0fbf96f91b2234e635`. Both variants compile identical
test/measurement sources; the only production-source difference is the
four-line `receiveFrames` addition.

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

Native qualification is recorded here after the paired workflow finishes. No
measured memory or speed result is asserted by this unqualified draft.

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
The paired experiment is pinned to its research branch. Future merged-source
regression coverage belongs to the frame-step timestamp workflow.

A concurrent branch, `perf/video-frame-exit-lifetime-668a`, independently
investigates the same scratch-frame lifetime with iteration-scoped cleanup.
This investigation uses function-scoped cleanup, exact source-allocation free
callbacks, output-admission rejection coverage, and explicit fallback and EOF
lifetime tests. The production fixes overlap and should be reviewed as
alternatives; this report does not claim an additional cumulative memory saving
over that branch.
