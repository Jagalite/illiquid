# Release completed deinterlacing storage at EOF

## Finding

The decoder-owned BWDIF filter graph retained full-resolution input pixels after
all output fields had been delivered. The decoder and session can remain alive
while the player is paused at the end of a file, so waiting for reset or
destruction prolonged those allocations beyond their useful lifetime.

This is bounded retention, not unbounded playback-length growth. The change
reduces idle storage after interlaced playback reaches EOF; it does not reduce
the temporal window needed during active deinterlacing.

The frozen baseline is main at
`6f70cd2446fc6ef38d4e5a0fbf96f91b2234e635`.
The only production file changed is
`Sources/IlliquidNativePlayback/Media/VideoDeinterlacer.swift`.

## Why the storage remains alive

The application's `VideoDeinterlacer.drain` closes the filter input and
receives the remaining output. Previously it left the graph, source, and sink
allocated. `MediaSession.videoDecodeLoop` drains the decoder and enqueues
end-of-stream without destroying the decoder; normal end-of-file handling pauses
the presentation.

In the pinned FFmpeg 8.1.2 source, BWDIF uses the YADIF temporal-frame machinery.
The EOF path emits its last fields and sets an EOF flag, while
`ff_yadif_uninit` frees the stored previous/current/next frames. The final
references can share backing storage, so counting frame pointers would
overstate unique pixel memory.

Upstream API/source references:

- [YADIF shared implementation, FFmpeg 8.1](https://www.ffmpeg.org/doxygen/8.1/yadif__common_8c_source.html).
- [Buffer sink EOF contract](https://www.ffmpeg.org/doxygen/8.1/group__lavfi__buffersink.html).
- [AVBuffer ownership contract](https://www.ffmpeg.org/doxygen/8.1/group__lavu__buffer.html).

The local source archive was verified against the repository's dependency and
corresponding-source manifests. Its SHA-256 is
`464beb5e7bf0c311e68b45ae2f04e9cc2af88851abb4082231742a74d97b524c`.

## Change and preserved behavior

After `av_buffersink_get_frame` returns EOF, free the graph and clear its
source/sink pointers. EAGAIN, cancellation, and a throwing output consumer do
not establish EOF and therefore do not retire the graph.

Keep the terminal state and remembered format. Same-format input after drain
still requires reset; changed-format input preserves its existing
reset/reconfigure behavior. Fresh progressive input still bypasses the filter.
Delivered output owned by the caller remains valid.

A drain interrupted after input EOF can now be resumed. EOF is submitted once;
a later call receives remaining fields until sink EOF permits retirement.
A callback that throws has already received its field, so retry does not
redeliver that field. This is an intentional lifecycle correction alongside
the memory improvement.

## Measured input-buffer retention

Linux x86-64, Swift 6.3.2, pinned FFmpeg 8.1.2. The experiment uses the complete
baseline and candidate Swift class with real FFmpeg filters. Only the unavailable
CoreVideo import/hardware guard is adapted on Linux; no filtering, allocation,
or AVFrame ownership implementation is replaced.

The following figures are **live tagged input backing bytes after complete
drain while the deinterlacer remains alive**, with no output retained by the
consumer. They include the input allocation's FFmpeg padding.

| Workload | Baseline bytes | Candidate bytes | Released MiB |
| --- | ---: | ---: | ---: |
| Empty stream | 0 | 0 | 0 |
| Progressive 1920×1080 control | 0 | 0 | 0 |
| One 720×576 interlaced input | 645,504 | 0 | 0.62 |
| 720×576 interlaced | 1,291,008 | 0 | 1.23 |
| 1920×1080 top field first | 6,267,648 | 0 | 5.98 |
| 1920×1080 bottom field first | 6,267,648 | 0 | 5.98 |
| 3840×2160 10-bit stress case | 50,135,808 | 0 | 47.81 |
| Interlaced stream with progressive tail | 3,133,824 | 0 | 2.99 |
| Resolution/color format change | 6,267,648 | 0 | 5.98 |

The separate retained-output control deliberately holds the final progressive
frame, which shares the input allocation. Both variants correctly retain
3,133,824 bytes after drain, and its pixels remain identical. After the caller
releases that frame, the candidate reaches zero; the baseline still retains
3,133,824 bytes until reset. This demonstrates that retirement releases only
ownership that is no longer needed.

All observed counters are identical across repetitions and optimization levels.
The 4K case is a synthetic stress workload within the existing input-frame limit,
not a claim about the prevalence of interlaced 4K content.

## Qualification

The final cohort contains **100 fresh measurement processes and 50 complete
baseline/candidate output comparisons** across ten workloads:

- One debug comparison per workload.
- Four release comparisons per workload, with two AB and two BA orders.
- Identical complete visible pixel planes and timing/format/color metadata in
  every comparison, including identical output across optimization levels.
- Output count, repeated-drain idempotence, allocation conservation, retained
  output validity, and final reset cleanup checked in every process.

The new lifetime suite contains eight test functions and fifteen parameterized
cases. It passes in debug and release with Swift warnings treated as errors.
The baseline builds in both configurations and then fails 24 expectations in
each, reproducing the retention and interrupted-drain defects. Build failures
were rejected during harness development and are excluded from the final cohort.

Coverage includes TFF/BFF, retained output, a progressive tail, cancellation
before/between/after the final fields, throwing consumers, reset/reuse,
destruction, and same/changed-format input after drain. Tests use safe observer
references for refcount assertions; the separate measurement driver uses final
free callbacks without an extra observing owner.

An independent review checked the production lifetime transitions, regression
coverage, measurement ownership, output comparisons, and receipt integrity.

## Measurement boundary and remaining native qualification

The C probe wraps actual `av_frame_get_buffer` allocations, moving each
original reference under a custom final-release callback. It records
`AVBufferRef.size` and drops the original reference before reporting release.
This observes final release of the tagged input allocations, not merely a
decrease in their reference counts.

The study does **not** measure process RSS, allocator page return, the entire
filter graph's heap, filter-created output pools, CoreVideo/Metal allocations,
whole-player RAM, frame rate, energy use, or latency. The Linux FFmpeg build has
external x86 assembly disabled; no execution-speed claim is made. Real codec
buffer sizes can vary with format, stride, padding, and allocator behavior.

The dedicated macOS workflow uses the reviewed native SDK, real CoreVideo,
the same memory/parity cohort, and the full native application test graph.
It explicitly generates and checks both interlaced container fixtures before
running the existing decoder/cadence/seek tests and new lifetime tests.
Consult the PR's current workflow result for native qualification; local Linux
results alone do not establish macOS hardware-transfer or end-to-end playback
behavior.

## Evidence and reproduction

- [Runner and methodology](../Benchmarks/DeinterlacerEOFMemory/README.md).
- [Final Linux summary](../Benchmarks/DeinterlacerEOFMemory/evidence/linux/summary.json).
- [Complete observation and source receipt](../Benchmarks/DeinterlacerEOFMemory/evidence/linux/receipt.json).
- [Commands and log hashes](../Benchmarks/DeinterlacerEOFMemory/evidence/linux/commands.json).
- [Complete compressed output fixtures](../Benchmarks/DeinterlacerEOFMemory/evidence/linux/payloads).
- [Native qualification workflow](../.github/workflows/deinterlacer-eof-memory.yml).
