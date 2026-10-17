# Playback research: packet progress and native presentation evidence

**Date:** October 17, 2026.  
**Baseline:** PR #5, `3c7b84c425cf15cdbaccfd2b4829f3181130963f`, tree `51ce29070360a5edd54abd77d1bc6c70ccb30cf6`.  
**Status:** experimental secondary-reader implementation and executed component research. The proposed native changes are a nested laboratory patch, not enabled production code. No playback default or renderer was changed.

## Executive decision

The packet-progress approach avoids the earlier stream-filtering pacing failure without using injected I/O errors. It leaves every stream enabled and returns either an owned selected packet or a value-only timing observation for an unselected packet. The native read-ahead gate still sees all the timing observations it previously used, but need not retain unused payloads while waiting.

The final prototype preserves every compared event, selected packet and read-ahead boundary in the fixed cohort. Through the actual Swift input executor, several selected-subtitle scenarios are approximately 6–15% faster, with absolute savings of fractions of a millisecond to about one millisecond per unpaced test loop. Results are not universally faster, and logical I/O bytes are unchanged. The main-reader implementation is deliberately unchanged after an initial shared-wrapper design regressed a control.

This turn also retrieved completed native CoreMedia measurements from PR #5's existing macOS CI. Validated format reuse saves approximately 1–2 microseconds per sample in stable-format scenarios, but loses when color attachments change every frame. Those are real native component observations on a virtualized Mac runner, not a displayed-playback or energy result.

**Recommendation:** retain the packet-progress implementation for native integration qualification, not automatic rollout. It is a safer candidate than global stream discard or artificial AVIO EAGAIN. Treat format reuse as a small presentation optimization, not the next major playback bottleneck.

## 1. Reconcile the repository before adding work

Main is still `8c3cc3d4008d5d1b8d436bcf2d51d891382b6548`, but PR #5 has newer playback changes. It already contains direct AVPacket ownership, the oversized initial recovery-keyframe guard, the queue invalidation fixes, and removal of redundant producer wakeups. These are retained, not credited as new gains.

The selected PR baseline blobs were independently verified:

| File | Git blob |
|---|---|
| `FFmpegDemuxer.swift` | `0fb75688f7bbdfb6c1e3bfab0000a7241b5680a7` |
| `FFmpegPacket.swift` | `be28cdb3b568fa9adf7b9bf0da8a74bc2d715d4d` |
| `PacketQueue.swift` | `ed52718d3bd42d1ebbd157343334be2bc6b6cc91` |
| `FixedRingBuffer.swift` | `f381657f22d07f49941b05afbd0c2549a2d98b1e` |

GitHub Actions run `38989970053` at this commit completed `focused-core`, `native-lifecycle`, and `native-presentation-research` successfully. The native lifecycle job builds the app graph and runs its targeted filter. This is newer evidence than the conversation's earlier local-only status. It does not qualify the entire test suite, rendered output, energy or fixture-gated tests whose inputs were absent. New prototype code here was not part of that earlier run.

This research is isolated from concurrent filename, subtitle-import and playback-core recovery PRs. It should be reviewed as a stacked research change based on PR #5, not overwrite those branches.

## 2. The new API and its limits

The current secondary subtitle reader gates DTS/PTS before filtering by selected stream. Earlier experiments showed that disabling all other streams, or keeping only one sentinel stream, can remove the very events that bound its read-ahead. Injecting EAGAIN inside container parsing was not a safe substitute.

The new `FFmpegPacketReadStep` has two cases:

- `packet`: the existing reference-owning `FFmpegPacket`, only for selected payloads;
- `progress`: stream index, PTS, DTS, time base and source generation, with no AVPacket pointer, payload or side-data ownership.

Each valid completed demux packet still produces one result. Missing timestamps remain missing; progress is not EOF. Genuine EOF is the optional read's nil result, and existing errors/cancellation remain thrown. The demuxer still evaluates terminal corruption before returning either case. It does not alter stream discard flags, probe budgets, packet order, decoder threads, AVIO size or queue capacities.

`FFmpegInputExecutor` routes the proposed method through the same serial context and operation-token mechanism. The proposed MediaSession integration applies generation checks and the same timestamp gate, then extracts a selected payload. Existing subtitle test-reader overrides still map to owned packets.

**This does not stop I/O or parsing in the middle of one packet.** A single `av_read_frame` call may still perform substantial work or block in the operating system. There is no strict byte or wall-time guarantee, no additional cooperative-I/O checkpoint, and no claim to solve a stalled NAS. FFmpeg's packet API separates a completed reference-counted packet from the parsing/read work needed to produce it [R1, R2].

The initial design routed the main reader through the new enum as well. Its MKV control regressed by roughly 15% directly and 28% through the executor in that exploratory cohort. The final design preserves the original main `readPacket` body byte-for-byte and uses a separate secondary loop. This duplication is acceptable for an isolated experiment, not an ideal permanent maintenance design. Native adoption needs safe factoring or a structural guard that keeps retry/EOF policy synchronized.

## 3. What ran and how

The new cohort ran on shared Linux x86-64, AMD EPYC 9V74, five affinity-visible logical CPUs and a four-CPU-equivalent quota. Swift 6.2.1 compiled with `-O -swift-version 6 -warnings-as-errors`; debug builds were used for correctness. FFmpeg 8.1.2 was built from the repository archive with network and external x86 assembly disabled. It is not the optimized macOS dependency configuration.

FFmpeg CLI 7.1.5 generated synthetic ordinary 12-second 1280x720 H.264/AAC MP4/MKV/TS files and 60-second 320x180 sparse-subtitle MP4/MKV files. Gap variants omit audio or video packets between 20 and 50 seconds while preserving timestamps. The first nonempty sparse cue is at 45 seconds. OS pages were warm and host activity was not quiesced.

The harness compiles the actual packet owner, read/retry logic, complete Swift input executor, read-ahead gate and queue. Real FFmpeg open/probe/read/seek and reference-counted buffers execute. A narrow stream-index/start-time projection replaces UI media metadata; CoreMedia-only time helpers are omitted; native subtitle acquisition is an uncalled trap. The full MediaSession graph, subtitle/audio decoding, VideoToolbox and presentation do not execute.

Final primary evidence consists of **448 timing observations**, **48 separately metered allocation observations**, and **72 verification processes**. Timing pairs alternate actual AB/BA executable order over seven rounds. Allocation groups have three repeats. Packet hashing and allocation metering are absent from the timing binary. Open/probe setup is recorded separately and excluded from the read-loop tables. No completed outlier is removed.

The first shared-wrapper cohort is retained separately as a rejected prototype, not mixed into these numbers. The existing 70 macOS CI timing observations are separately attributed; they are not 70 newly executed local runs.

## 4. Pacing and selected output are preserved in this cohort

Thirty-two paired role/route/scenario groups compare all-stream event sequences and selected packet receipts. Events include stream, PTS, DTS, time base and generation. Selected receipts additionally compare size, duration, key/corrupt indicators, payload SHA-256 and side data. Four resumed fixtures per route advance horizons from 30 to 40 to 55 seconds and then EOF; each pending future packet is delivered once, and final selected packets match uninterrupted references.

The main sparse/gap checkpoints remain identical:

| Fixture | First stopping timestamp | Post-probe logical bytes | Events observed |
|---|---:|---:|---:|
| Sparse MKV | 30.016 s | 1,376,256 | 2,312 |
| Sparse MP4 | 30.015833 s | 1,343,488 | 2,311 |
| Audio-gap MKV | 30.033 s | 1,245,184 | 1,843 |
| Video-gap MKV | 30.016 s | 1,048,576 | 2,011 |

Unlike selected-only filtering, the new path does not jump to the 45-second subtitle before yielding. It also does not save read bytes: preserving the same demux path intentionally preserves those bytes. Sixteen additional absent-selection verification processes form eight matching pairs, returning no selected payloads without losing progress or misreporting early EOF.

These checks establish packet and pacing behavior for this fixed cohort, not decoded pixels, audio continuity or native subtitle reconstruction across every format.

## 5. Performance results and controls

Read-loop medians through the actual Swift input executor, seven fresh processes per variant:

| Workload | Baseline | Packet progress |
|---|---:|---:|
| MP4 subtitles, full read | 1.688 ms | 1.576 ms |
| MKV subtitles, full read | 1.781 ms | 1.653 ms |
| Sparse MKV, 30-second horizon | 2.880 ms | 2.701 ms |
| Audio-gap MKV, horizon | 2.753 ms | 2.330 ms |
| Video-gap MKV, horizon | 2.506 ms | 2.228 ms |
| Sparse MKV, resumed to EOF | 6.091 ms | 5.158 ms |
| MKV audio, full read | 1.721 ms | 1.831 ms |
| Main all-packet TS control | 3.013 ms | 3.157 ms |

The last two rows are negative controls: approximately 6.4% and 4.8% slower medians. The all-packet TS read method itself is unchanged, so shared-host variation and compilation/layout effects may contribute; this cohort does not isolate their causes. Do not discard the result or call it a guaranteed nonregression.

Direct-call controls are also mixed. Normal MKV subtitle reading is approximately 0.9% slower and MKV audio about 6% slower, whereas sparse/gap horizon cases improve by approximately 11–16%. No unpaced packet-loop result is an FPS, battery, real-time latency or whole-app CPU improvement. Small absolute savings limit the practical significance until native traces establish call frequency and contention.

## 6. Allocation and ownership results

Selected examples through the actual executor, three separately metered repeats:

| Workload | Requests before / after | Requested bytes before / after |
|---|---:|---:|
| Normal MP4 subtitle read | 3,747 / 2,823 | 181,672 / 113,296 |
| Normal MKV subtitle read | 4,703 / 3,779 | 4,566,947 / 4,498,571 |
| Sparse MKV to horizon | 11,667 / 9,355 | 2,505,279 / 2,334,191 |
| Main all-packet MKV control | 4,703 / 4,703 | 4,566,947 / 4,566,947 |

The reduction is one Swift wrapper allocation for each unselected packet in these examples. PR #5 already removed the second AVPacket-header allocation; that earlier change is not counted again. This prototype still allocates a temporary AVPacket header and allows normal demux payload allocation before releasing unused output.

The Linux meter counts malloc/calloc/realloc only. It excludes aligned allocation APIs used by FFmpeg, does not subtract frees, and is neither total allocation traffic nor live/peak heap, RSS, macOS physical footprint or GPU memory. The MP4 tracked-byte reduction must not be generalized to the whole decoder or player.

A separate ownership regression uses actual 8 MiB AVBuffer payloads and blocks the real read-ahead gate at a future timestamp. With one deliberately retained observer reference, the baseline has two payload references for both selected and unselected packets. The candidate has **one for unselected progress, two for selected packets**. Thus its secondary handoff releases an unused payload before waiting, while preserving needed future subtitle data. This proves the tested owner is removed, not that the operating system returns 8 MiB or that no other pipeline owner exists.

## 7. Native presentation evidence now available

Existing successful CI run `38989970053`, artifact `12084653162`, was downloaded and its SHA-256 verified as `599cd8c56a6ee8909536ef1541cc37db9560bde7815f81c662484901d3b8d48b`. Raw rows and actual command order were independently rechecked.

The runner reports macOS 26.6.2 arm64, Xcode 26.6/Swift 6.3.3, `VirtualMac2,1`, three CPUs and approximately 7 GiB RAM. This is real CoreMedia/CoreVideo execution on a virtualized runner, not a physical retail Mac playback or energy benchmark.

Two preallocated 1080p image buffers are used, with 100 warmup iterations excluded. Each process constructs 10,000 NEW CMSampleBuffers. Only format descriptions may be reused, after `CMVideoFormatDescriptionMatchesImageBuffer` accepts the image [R3]. Seven AB/BA rounds per scenario produce 70 observations:

| Format/sample construction | Fresh description | Validated reuse |
|---|---:|---:|
| Stable 8-bit bi-planar video range | 7.951 us/frame | 6.362 us/frame |
| Stable BGRA | 8.620 us/frame | 7.563 us/frame |
| Stable 10-bit PQ/BT.2020 attachments | 8.836 us/frame | 7.120 us/frame |
| Color attachments alternate every frame | 8.954 us/frame | 9.499 us/frame |
| Cache reset every 90 frames | 6.751 us/frame | 5.762 us/frame |

Stable-format savings are roughly 12–20%, but only about 1–2 microseconds per frame. Alternating-color reuse creates a new description every frame and is about 6.1% slower. Samples still allocate; renderer-held buffers are not recycled. The 85 verification checks cover subtype, dimensions, row alignment, selected color attachments, mutation/removal, resets and retained sample timestamps. They do not cover every HDR attachment, VideoToolbox output, renderer ownership, visible pixels or output deadlines.

The production presenter remains unchanged. A last-description cache is a plausible small native change, but must preserve attachment validation, flush/source fences and renderer lifetimes. It should not distract from larger decode, I/O and deadline bottlenecks.

## 8. Validation, delivery and remaining work

Forty regression assertions per variant passed in both release and debug. Tests use the actual gate and executor for generation resets, close/EOF waiting, precancelled opening, concurrent callers and recovery by a later seek. Regression-only demux faults check interruption, bounded EAGAIN/INVALIDDATA retries and terminal corruption on an unselected packet. Selected payloads remain valid across subsequent reads and demux release. No test claims bounded cancellation of an actual blocked OS filesystem call.

The receipt checker performs 3,800 comparisons, checks actual process order and timed build hashes, and rejects six damaged datasets: missing row, duplicate, wrong order, altered selected count, hashing in timing, and wrong command executable. Regression-only ownership coverage was extended after timing; its final source hash is separately recorded, and timing/verification/allocation binaries were unchanged.

A new packaged build reproduced every generated Swift source. Four regression executions and six packet/event/frontier smoke processes passed. Sources/Tests in the published research branch retain PR #5's production behavior; `native-candidate.patch` is applied only to an isolated copy by the runner. No subagents were executed; separate test processes and CI are not independent agent reviews.

Next qualify the proposed secondary API in the complete native MediaSession with actual text/bitmap acquisition, seeks, track switches, cancellation, EOF and A/V continuity. Include missing/gapped streams, invalid timestamps, large packets and failure recovery. Address duplicated read policy before promotion. Run the native format-cache change separately with real renderer and attachment/lifetime checks. Preserve the queue/recovery fixes and obtain matched visible playback, physical footprint and energy evidence before claiming player-level gains.

## References

Repository baseline and CI provenance are stated above. Reproduction is in `Benchmarks/PlaybackPacketProgress/README.md`; compact results in `RESULTS.json`; full raw receipts and rejected prototype evidence accompany the research archive.

[R1] FFmpeg 8.1 demux/probe/read contracts: https://ffmpeg.org/doxygen/8.1/group__lavf__decoding.html

[R2] FFmpeg AVPacket allocation/reference ownership: https://ffmpeg.org/doxygen/8.1/group__lavc__packet.html

[R3] Apple image-buffer matching: https://developer.apple.com/documentation/coremedia/cmvideoformatdescriptionmatchesimagebuffer(_:imagebuffer:)

Numerical results come from executed receipts, not external documentation. New Linux observations and previously completed native CI remain separately attributed.
