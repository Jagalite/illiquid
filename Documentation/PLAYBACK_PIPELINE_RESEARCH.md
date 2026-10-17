# Illiquid playback pipeline research: first pass

Date: October 16, 2026. Baseline: `8c3cc3d4008d5d1b8d436bcf2d51d891382b6548` (merged non-decoding PR #4).

Status: two production-source candidates, packet-level experiments, and a full-pipeline qualification plan. This is not a completed native playback-performance qualification. Previous non-decoding improvements are part of the baseline, not credited again.

## 1. Goal and decision

The research now covers the entire playback path: source opening and reading, caches, demuxing, compressed and decoded buffering, hardware/software decoding, conversion and buffer ownership, audio/subtitles, display pacing, seeking, and competing preview work. Optimize useful playback, not isolated throughput at the expense of latency, correctness, memory, or energy.

This first pass keeps the implementation deliberately narrow. The demuxer can transfer its allocated AVPacket header directly into the Swift owner rather than allocate a second header and move references. The optional hardware-recovery GOP cache also now rejects an oversized first keyframe, fixing an existing exception to its stated 32 MiB bound. Neither change lowers image quality, changes codec preference, increases threads or buffers, or discards playback packets.

The packet experiment has mixed timing results. Direct ownership reduced the median demux-loop time by about 11.0% for MP4 and 2.5% for Matroska, but increased it by about 2.6% for MPEG-TS. This supports a simpler ownership path with fewer explicit allocations, not a universal throughput improvement. The native demuxer and end-to-end player need qualification before promotion. The recovery-bound correction is independently reviewable.

## 2. Current architecture and where to measure

The following reflects inspected source at the baseline, not assumptions about a generic FFmpeg player.

| Stage | Existing implementation | Next measurement and candidate experiments |
| --- | --- | --- |
| Source and I/O | FFmpegInputExecutor serializes AVFormatContext ownership and C calls; interruption uses operation tokens. Opening has a deadline and bounded retained-worker admission. FFmpegDemuxer currently accepts file URLs. | Separate open, stream probing, first packet, sequential reads, seeks and cancellation. Record logical AVIO bytes per input role, read latency and physical File Activity separately. Compare local APFS, external storage and a disposable delayed/stalled mount. Do not treat a network-mounted file as an implemented HTTP streaming transport. |
| Packet ownership and demux | Each delivered packet previously allocated a temporary header plus an owned header. Per-read dispatch, retry policy and stream filtering are already explicit. | This pass compares moving, taking ownership and reusable scratch headers. Next investigate dispatch overhead and duplicated probing only after measuring their share of real workloads. |
| Compressed buffering | Video: 96 items / 32 MiB / 4 seconds; audio: 192 / 8 MiB / 4 seconds; subtitle: 64 / 4 MiB / 30 seconds. Queues use fixed rings and blocking backpressure. A bounded fair interleaving router exists but is not the default. | Sweep item, byte and duration budgets separately. Measure starvation, producer wait time, pending interleaving, seek-flush cost and total retained bytes. Test poorly interleaved streams and a slow video consumer without starving audio. Do not replace already-existing ring buffers or enable fair dispatch from a toy test alone. |
| Decoded buffering | Video queue defaults to 12; audio to 48. A separate video-capacity gate accounts for pool capacity and renderer retention allowances. | Track application-owned, queued, presenting and renderer-retained surfaces. Queue slots are not the total number of live pixel buffers. Smaller pools can trade memory for stalls; larger ones can hide latency and amplify memory. |
| Decoding and seeking | Hardware, copied-hardware and software routes are observable. Guarded preroll skipping and software seek acceleration already exist. | Compare verified routes by codec, bit depth, resolution, frame rate and GOP structure. Measure decode CPU, throughput margin, first usable frame, exact landing, fallback/handoff, and old-generation retention. Do not force hardware or additional decoder threads globally. |
| Conversion and copies | Frames carry planar ownership, capacity permits, PTS, geometry, color, bit depth and HDR metadata. | Attribute copy bytes and conversion time separately from decode. Verify YUV/BGRA output, full/limited range, chroma siting, HDR and geometry. Preserve native surfaces when possible; a route label alone does not prove zero copying. |
| Display and synchronization | MediaSessionSnapshot distinguishes successful submission from renderer clock evidence; late/drop/visible fields can be unavailable. | Capture actual visible pacing and audio synchronization on supported Mac displays. Test 24/30/60 fps and relevant 60/120 Hz output, variable frame rate, resize, fullscreen, hidden windows and PiP. Never substitute submitted frames or unavailable counters for displayed frames or zero drops. |
| Competing work | Selected subtitles can open an independent input; nonzero audio delay can add another. Preview extraction competes for decode, I/O and conversion resources. | Measure per-role reads, subtitle render/lock time, audio underruns and cold preview contention during visible playback. Compare subtitle off/text/animated ASS/bitmap and preview off/on without omitting the cost from the product configuration. |

Key source locations: `Media/FFmpegInputExecutor.swift`, `Media/FFmpegDemuxer.swift`, `Media/FFmpegPacket.swift`, `Media/MediaSession.swift`, `Media/VideoDecoder.swift`, `Playback/PacketQueue.swift`, and the presentation/runtime components. This is a targeted audit, not a line-by-line audit of every native source file.

Existing metrics already cover packet producer waits, deferred demux packets, renderer starvation/backpressure, seek phases, pool capacity/timeout events, actual decoder route and known frame ownership. Reuse those signals. Add missing boundary timings in the worker that owns the operation, not synchronous main-thread queries into blocked I/O. Measure instrumentation overhead separately; avoid per-packet strings, unbounded trace arrays, and timers in the primary resource comparison.

## 3. Experiment P01: packet-header ownership

### Production change

`readPacket` allocates one optional header slot. EOF and errors free that slot through the existing defer. Successful delivery calls `FFmpegPacket(taking: &slot, ...)`, which clears the caller's slot and transfers the same pointer to the Swift wrapper. Wrapper destruction still calls `av_packet_free` exactly once. The existing `moving:` initializer remains available for callers that need a reusable scratch header.

The previous `av_packet_move_ref` path already moved references without copying packet payloads. This change removes an extra header allocation/free and explicit reference-move operation; it is not a new zero-copy video decoder. Stream selection, timestamps, side data, corruption flags, generation, retry limits, EOF error checks and seek policy are unchanged.

### Measurement design

The timing program is a standalone C model of those ownership paths using real installed FFmpeg. It is not the actual Swift FFmpegDemuxer or its serialized input executor. Three variants were tried: baseline temporary-plus-destination, direct adoption, and reusable scratch-plus-destination.

The synthetic fixtures are eight seconds of 640x360 60 fps H.264/AAC in MP4, the same streams remuxed to Matroska, and MPEG-2/MP2 in MPEG-TS. Each fresh process opens, probes and fully demuxes the fixture 100 times, retaining up to 96 packets in a FIFO ring before release. Open/probe/optional seek time is recorded separately from the demux loop. There is no playback pacing, pixel decode, GUI, native frame queue, or rendering. Fixture creation precedes measurement; OS caches were not purged.

There are 81 completed timing observations: three fixtures, three variants, nine repetitions. Variant order rotates by repetition and the actual recorded order was checked. All completed observations, including outliers, remain. The host is shared Linux x86-64 on an Intel Xeon Platinum 8573C, GCC 14.2.0 and FFmpeg 7.1.5. It is not the app's locked native SDK or Apple hardware.

### Results

Demux-loop milliseconds for 100 scans per process; median (minimum-maximum), nine processes per cell:

| Fixture | Baseline | Direct adoption | Reusable scratch |
| --- | ---: | ---: | ---: |
| H.264/AAC MP4 | 133.89 (125.68-153.29) | 119.11 (110.96-151.06) | 121.57 (114.18-143.81) |
| H.264/AAC Matroska | 152.16 (139.05-183.09) | 148.42 (127.66-356.23) | 136.60 (125.27-209.55) |
| MPEG-2/MP2 TS | 338.39 (321.70-367.30) | 347.17 (320.16-428.89) | 338.97 (323.68-368.75) |

The MP4 saving is approximately 0.148 ms per complete eight-second input scan in this warm, unpaced kernel. It is not 11% of player CPU, not faster-than-real-time playback quality, and not 11% faster visible seeking. Matroska's adoption maximum is notably worse; overlapping ranges and shared-host conditions do not establish improved tail latency. TS is a negative result and remains a required native non-regression case.

For the 85,600 MP4 or Matroska packets processed per observation, explicit benchmark header allocations are 171,300 before and 85,700 with adoption; the 100 extra calls are terminal EOF reads. Explicit moves fall from 85,600 to zero. The scratch alternative has the same allocation count but retains the move operation. TS follows the same formula for 81,400 packets.

These counters count only explicit calls in the test program. They do not measure FFmpeg-internal allocations, all heap traffic, packet payload bytes, physical I/O, resident RAM, GPU memory, or energy. No allocation-interposer experiment was run in this pass. Reusable scratch wins one fixture but not every fixture; direct adoption was selected as the narrower lifetime change, still pending native qualification.

### Packet correctness

Twelve scenarios compare all three variants: three containers, retention of one or 96 packets, and beginning-of-file versus an explicit seek to three seconds. All 36 invocations produce matching SHA-256 receipts containing packet order, stream, timestamps, duration, position, flags, time base, full payload and every side-data type/size/byte. This is packet parity, not decoded-pixel or audio-output parity. It does not exercise the native retry/cancellation code.

A separate Swift probe compiles the actual baseline and candidate FFmpegPacket source with real FFmpeg allocation/reference operations. A narrow bridge supplies public packet declarations and platform-independent supporting value types; it does not simulate buffers. The candidate passes 8,014 assertions in each of debug and optimized builds, including transfer identity, payload/side-data preservation, missing-pointer rejection and the retained moving API. An AVBuffer free callback proves a separately retained buffer remains alive after wrapper release and is freed once after the last reference is released. Repeating build configurations is not a count of additional independent tests.

## 4. Experiment P02: enforce the recovery GOP bound

The existing keyframe branch reset the optional recovery cache and returned before checking its 32 MiB byte limit. A single keyframe larger than that limit could therefore remain retained. The baseline Swift probe reproduces a replay count of one for the oversized keyframe in both build configurations; the candidate returns zero.

The new guard rejects that entire recovery GOP and ignores its dependent tail until a new bounded keyframe arrives. The 32 MiB boundary remains inclusive, the 512-packet bound remains, and generation fencing is retained. This affects only optional compressed-packet replay used during hardware recovery. It neither rejects the packet from normal playback nor changes the fallback seek policy.

The memory claim is a corrected logical retention bound for this owner. The packet may still be held by the decoder, another queue or the caller; no process-footprint reduction for an actual movie was measured. Regression cases cover old-GOP invalidation, oversized keyframe plus tail, next-keyframe recovery, exact byte boundary, overflow, item limit and generation changes.

## 5. Native qualification before merging

Six `PacketOwnershipTests` tests are included. Five are unconditional packet/cache tests; the real demux lifetime test requires `ILLIQUID_PACKET_OWNERSHIP_FIXTURE`. It keeps old packet objects while reading ahead and seeking, checking content, timestamps, unique headers and generation. These native tests and the modified demuxer pass syntax parsing here, not SDK typechecking or execution. The complete app and its decode/display pipeline were not built or run in this environment.

Run the actual locked SDK release build, packet tests and existing read-failure, seek, recovery, teardown and native fixture suites. Compare baseline and candidate visible playback before promoting the header optimization. Treat the recovery-bound fix as independently reviewable. Do not change timeout or quality gates to make the candidate pass.

The first end-to-end cohort should cover: empty launch and first media; 1080p/4K H.264 and HEVC; software VP9/AV1 where supported; a long-GOP seek case; Matroska with text/ASS/bitmap subtitles; and a slower or bursty file source. Keep fixtures, audio output, window dimensions, display refresh, production decoder policy, preview settings, cache state, dependency versions and power/thermal conditions fixed. Record actual routes rather than assuming hardware support from a filename or preference.

Report medians and distributions for open-to-usable-playback, seek request-to-correct frame, recovery, and control feedback. Separately record physical footprint, process CPU normalized to one core, system/GPU/WindowServer cost where available, dropped/late frames, audio underruns, queue horizons and idle wakeups. Unknown display counters are unknown, not zero. Warm-cache fresh-process tests are not cold-storage tests. More than nine interactions are needed to characterize p95/p99 tails.

## 6. Next experiments, in order

1. Establish a matched visible Mac baseline and bottleneck attribution across I/O, decode, conversion, queue waiting and display. Preserve full traces and negative controls. This is higher value than accumulating packet micro-optimizations without playback measurements.
2. Qualify buffering and input policy: controlled bandwidth/jitter and cancellation; count/time/byte budget sweeps; fair versus current demux; per-role read amplification from subtitles, audio delay and previews. Keep one owner for native input, bounded pending work and explicit generation fences. Custom caching must be justified beyond the existing OS cache and compressed queues.
3. Qualify decoder routes and handoff: hardware versus software, copied versus retained surfaces, thread counts, long GOPs, B frames, format changes and exact seeks. Preserve pixel/timestamp/audio correctness. Historical CPU advantages do not establish seek or energy advantages.
4. Measure conversion and display ownership: stride-aware copy volume, color conversion, surface reuse and actual output pacing, including resize/PiP/hidden transitions. Do not globally shrink pools while renderer retention and old-generation lifetimes remain unmeasured.
5. Test interference and sustained playback: cold previews, animated subtitles, slow storage, multiple sources, thermal constraints, sleep/wake and repeated seeks. A lower average CPU number is not a win if it increases stalls, wrong frames, audio drift or long-tail latency.

Each policy experiment should have a default baseline, an isolated switch, correctness gates and a retained unsuccessful outcome. No global cache, decoder, refresh-rate or thread-default change is made in this first pass.

## 7. Evidence and reproduction

See `Benchmarks/PlaybackPipeline/README.md`. `RESULTS.json` contains all 81 raw timing rows, fixture/source/binary hashes, the 12 packet-receipt comparisons, and four Swift probe build results. The accompanying investigation archive additionally retains full commands, original manifests, summaries and the exact timed C source.

Without development headers, the Linux benchmark uses an explicitly version-gated declaration of public AVPacket fields from FFmpeg n7.1.5. AVFormatContext is opaque. This bridge is test-only and must never replace the product SDK. The packaged source adds a missing avcodec.h include in the development-header branch; the executed no-header preprocessor output is byte-identical to the timed source. That SDK branch remains uncompiled here.

The timing orchestration was interrupted after 50 completed rows; remaining identities resumed only after source/binary/fixture hashes were checked. An early incorrect av_pkt_dump2 receipt prototype was rejected before the formal cohort and replaced with explicit packet receipts. A captured-output Python Swift runner stalled; the delivered shell runner completed all four builds. None of those abandoned attempts is counted as a passing measurement or native test.

Primary API references: FFmpeg `av_packet_move_ref`, `av_packet_free` and AVPacket ownership documentation; FFmpeg AVIOContext `bytes_read` (logical bytes, including cached reads); Apple VideoToolbox decompression and sample-buffer display APIs. These contracts motivate the experiments; the numerical results come only from the retained receipts.

- https://ffmpeg.org/doxygen/7.1/group__lavc__packet.html
- https://raw.githubusercontent.com/FFmpeg/FFmpeg/n7.1.5/libavcodec/packet.h
- https://ffmpeg.org/doxygen/trunk/structAVIOContext.html
- https://developer.apple.com/documentation/videotoolbox/vtdecompressionsession
- https://developer.apple.com/documentation/avfoundation/avsamplebufferdisplaylayer
