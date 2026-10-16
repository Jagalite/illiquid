# Illiquid playback: input roles, read-ahead, and decoder parallelism

**Date:** October 16, 2026.  
**Source baseline:** `8c3cc3d4008d5d1b8d436bcf2d51d891382b6548`, tree `ffba4f14b3f3bddc21143ae28123531467499edb`.  
**Integration branch:** `perf/playback-pipeline-phase1`, PR #5.  
**Status:** queue fixes preserved and pushed; new I/O and decoder-mode candidates are laboratory experiments, not enabled production policies. No sub-agent runner was available; the experiments and review were performed directly, not by independent agents.

## 1. Decisions from this pass

The existing queue fixes are retained: blocked producers no longer wake each other merely because they are waiting, and an invalidated producer can retire without waiting for new-generation work to drain. These are on PR #5, along with their regression suite. The branch's existing packet-ownership transfer and recovery-buffer cap are preserved rather than overwritten.

New experiments show that **fewer demuxed packets do not necessarily mean less I/O**, and **faster unpaced decoding does not necessarily mean faster playback startup**. Selective subtitle reading can dramatically reduce logical MP4 input, but the same strategy does not skip Matroska input bytes and can defeat the timing granularity of the current read-ahead gate. Altered seek packet histories also change decoded AAC samples in some tests. Decoder slice threading offers an intermediate memory/latency tradeoff only when the bitstream contains suitable slices; it does not help the one-slice control.

**No stream-discard, read-buffer-size, decoder thread-count/type, queue-size, renderer, or output-quality default changes are selected.** Keep these candidates isolated until native correctness and displayed-playback measurements support a specific route.

| Experiment | Evidence | Decision |
|---|---|---|
| P09: discard unselected streams after probing | Per-role scans in MP4/MKV/TS, two audio streams, sparse subtitles | Useful container-specific mechanism, not a blanket optimization |
| P10: custom AVIO buffers and injected callback delay | 4/32/256 KiB buffers; native-file controls; 500 microseconds per read callback | No universal buffer size; large buffers reduce calls but can over-read sparse data |
| P11: selected-stream seeking and read-ahead | 96 baseline comparisons, 18 packet-receipt differences | Preserve current production behavior; a discard toggle alone is insufficient |
| P12: actual AAC samples after seek | 36 decoder processes; 24 comparisons, 10 early sample-hash differences | No bitwise output-equivalence acceptance for generic filtering; audibility unmeasured |
| P13: frame versus slice threading | Two H.264 slice layouts, three strategies, actual decoded pixels | Keep both as explicit experiments; bitstream layout matters |
| P14: packet-availability-limited decoding | Synthetic 60 fps packet-availability schedule | Four frame threads double first-output wait here despite faster unpaced decoding |
| P15: retained-fix integration and CI | Pushed queue/test commits; selected tests rerun; native CI compile failure repaired; macOS app-graph/targeted-regression run passed | Kept fixes have native CI evidence; live output/performance qualification remains outstanding |

## 2. Scope, provenance, and measurement protocol

This run used Linux x86-64 on an AMD EPYC 9V74 host, five affinity-visible logical CPUs and a cgroup quota of four CPU equivalents. Clang 17 and Swift 6.2.1 were available. The host was shared, not quiesced or thermally controlled. Compare within this cohort, not against absolute values from the prior Intel-host report.

The complete source receipt's indexed tree matches the pinned main tree. New C experiments link **FFmpeg 8.1.2** built from the repository archive, with selected demuxers/decoders, pthreads and file I/O. Network, unused components, and external x86 assembly are disabled. This is not the optimized production macOS dependency configuration. The installed FFmpeg 7.1.5 CLI generated all fixtures; it is not the library used by the measured probes.

The I/O fixtures contain 64 seconds of repeated synthetic H.264 video, two AAC audio tracks at 48 and 44.1 kHz, and, where supported, sparse text subtitles. MP4 carries mov_text, Matroska carries SRT, and TS has no subtitle stream in this cohort. The three subtitle cues cover 0.5–8, 45–49, and 58–62 seconds. Repetition is by stream-copy of an encoded four-second segment; this is not a varied real-media library. Each multiplexed fixture is roughly 37 MB.

The decoder fixtures are separately encoded three-second 1080p60 H.264 clips, one with one slice per frame and one with four. Each has 180 frames, two B-frames and a 120-frame GOP. Pixel comparisons are **within the same file across decoder strategies**, not between those different encodings.

There are **272 new primary timing processes**: 110 native-file I/O, 90 custom-buffer I/O, 18 injected-latency I/O, 36 unpaced decoder, and 18 paced decoder observations. There are **252 separate primary verification processes**: 144 seek/frontier/scan, 66 buffer comparisons, six pixel-checksum decoder cases, and 36 AAC cases. A later 36-case AAC reproduction run and three packaged smoke runs are repeatability checks, not additional primary samples.

Each primary observation starts a fresh process. I/O pairs alternate actual AB/BA order. Buffer sizes rotate. The six-round unpaced decoder schedule places each strategy in each run position twice; the three-round paced schedule places each once. The checker inspects the emitted sequence rather than trusting the scheduling code. Compilation and fixture generation were completed before primary measurements; timed processes ran serially. OS caches are warm, no completed outliers were removed, and full ranges remain in the evidence. Three-to-six process repeats are screening evidence, not p95/p99 interaction measurements.

These are **real libavformat/libavcodec and filesystem operations**, but not the complete Swift input executor, MediaSession graph, VideoToolbox, conversion/pixel pools, audio resampler/output, subtitle renderer, CoreMedia presentation, GPU, or WindowServer. Logical bytes are not physical storage traffic. CPU work and Linux process peak RSS are not energy or macOS physical footprint. No installed app data, media or mounts were modified.

## 3. Input-role filtering: container-specific results

Illiquid's independent subtitle and delayed-audio inputs currently read packets and select the relevant stream at the application boundary. The experiment changes unselected streams to `AVDISCARD_ALL` **after** the normal `avformat_find_stream_info`, preserving the initial probing policy. FFmpeg documents this as a demux-selection mechanism [R1]; already buffered probe packets can still be returned.

The table measures **reading from the end of probing to EOF**, not opening a movie, initializing every concurrent input, or showing a frame. Five process samples per variant; milliseconds and exact logical AVIO byte counts:

| Container / selected role | All streams: read ms | Selected: read ms | Logical bytes, all → selected | Returned packets, all → selected |
|---|---:|---:|---:|---:|
| MP4 audio track 0 | 7.389 | 4.630 | 37,186,975 → 36,840,096 | 7,687 → 3,004 |
| MP4 subtitles | 7.579 | 0.391 | 37,186,975 → 131,072 | 7,687 → 10 |
| MKV audio track 0 | 7.821 | 5.784 | 37,087,475 → 37,087,475 | 7,684 → 3,008 |
| MKV subtitles | 7.820 | 4.663 | 37,087,475 → 37,087,475 | 7,684 → 13 |
| TS audio track 0 | 20.459 | 7.484 | 38,544,888 → 38,544,888 | 7,681 → 3,001 |

Sparse MP4 subtitles avoid about **99.65%** of logical input in this interval. MKV subtitle filtering still reads all the same bytes: it reduces packet delivery/parser work, not the amount of file data read. Audio interleaving likewise limits byte savings. The TS byte count can exceed file length because repeated logical reading is counted.

All full-scan selected packet receipts match within each container/role across the three discard modes, and all 66 custom-buffer verification comparisons match their native-file equivalents. Metadata hashes include codec parameters, stream shape, rates, time bases, disposition, duration, extradata and tags; this is selected metadata coverage, not every FFmpeg field or subtitle format.

Opening and probing remain separate costs. The filter is not active during probing, so those costs cannot be credited to it. For example, the MP4 video scan control changes 7.495 → 6.746 ms, while open-through-read medians are almost unchanged at 14.509 → 14.443 ms. The probe does not prove that three simultaneous input contexts multiply physical disk reads; OS and AVIO caching are different layers.

## 4. Buffer size trades callback count against unwanted reads

The custom AVIO path uses real `read` and `lseek` callbacks with a fixed initial buffer size. It is a laboratory adapter, not Illiquid's shipped input path. Sizes are measured separately from the native file protocol.

For selected MP4 audio, increasing the buffer from 4 to 256 KiB reduces callback count from **8,752 to 141** and read-stage median from **5.912 to 4.117 ms**, but increases logical bytes from **35,844,701 to 36,937,234**. For sparse MP4 subtitles:

| Buffer | Read callbacks | Read-stage logical bytes | Median read time |
|---|---:|---:|---:|
| 4 KiB | 9 | 36,864 | 0.372 ms |
| 32 KiB | 4 | 131,072 | 0.612 ms |
| 256 KiB | 3 | 786,432 | 0.448 ms |

A bigger buffer makes fewer calls but can consume far more data the subtitle reader does not need. The small time differences are noisy and not evidence for one app-wide setting.

In a separate experiment, every custom read callback incurs an injected **500-microsecond service delay**, including EOF attempts. Three paired samples give:

| Role | All streams | Selected stream |
|---|---:|---:|
| MP4 subtitles | 669.574 ms | 2.696 ms |
| MKV subtitles | 670.148 ms | 664.493 ms |
| MP4 audio 0 | 668.226 ms | 660.791 ms |

This isolates sensitivity to request count. It is **not a measured NAS, external-drive or SSD speedup**, and excludes actual storage scheduling, seek latency, bandwidth limits and cancellation behavior. Native-mode callback fields in the raw rows are uninstrumented zeros; only their AVIO counters are meaningful. Do not interpret them as zero physical reads.

## 5. Why generic discard is not ready: seeking and read-ahead

### Seek state is not independent of stream selection

FFmpeg's `avformat_seek_file` considers active streams, defined using their discard state [R2]. The tested global seek matches the production bounds/flags. An alternative restores all streams during seeking and enables filtering again only for reading; this is labeled `read-only` in the receipts.

Across 96 comparisons, **18 selected-packet receipts differ** after global seeks or at the read-ahead frontier. Some filtered audio streams start closer to the requested time rather than at the earlier video-aligned keyframe. The read-only alternative does not restore all Matroska preroll sequences. Selected subtitles can also retain a cue covering the target that a different global seek omits. A changed packet history is not automatically a regression or improvement, but it needs the actual decoder/subtitle reconstruction contract, not just equal packet counts.

### Decoded AAC differences survive the packet check

A separate C verifier creates a fresh AAC decoder and compares decoded samples in `[target, target+40ms)` and the following 160 ms. It runs two audio streams, MP4/MKV/TS, targets at five and 47 seconds, and all/selected/read-only modes: 36 processes, 24 comparisons against the all-stream baseline.

All comparison windows have matching sample counts and first-sample timestamps. Nevertheless, **10 comparisons differ in early raw sample hashes, and six still differ in the later window**. Four early differences converge in the later window. All TS cases match in this fixture; affected cases are MP4/MKV, including two Matroska read-only cases. A complete second run reproduced all 36 original receipts exactly.

These observations do not establish audible clicks, perceptual degradation or a specific decoder-state cause. Different preroll and timestamp/sample alignment need investigation; byte equality is stricter than perceptual equivalence. The probe has no resampler or audio-output device and does not reproduce all native decoder reuse/flush policies. **It does establish that generic filtering cannot currently claim unchanged decoded samples after these seeks.** No production discard policy was enabled.

### Sparse captions change the read-ahead checkpoint

`MediaSession.subtitleDemuxLoop` applies its time gate to returned packet timestamps **before** discarding unrelated streams. Unselected video/audio therefore provide frequent timing checkpoints. When libavformat skips them internally, the next returned subtitle may be much later.

A probe stops at the first returned DTS (PTS fallback) beyond the initial 30-second frontier, corresponding to where the existing gate gets a chance to block. In MP4, this first returned timestamp changes from about **30.000 to 45.000 seconds**. In Matroska it changes from **30.018 to 45.023 seconds**, and logical bytes consumed before that checkpoint rise from **17,415,495 to 26,140,948**—about **50.1% more**, not less.

This does not mean captions are displayed early; the native gate can hold the future packet. It means the work/read-ahead has already happened inside the demux call before that wait. This limited checkpoint model is not a full concurrent MediaReadAheadGate experiment. Filtering also needs to preserve byte/work limits and interruption checks inside any long interval that produces no selected packets.

**Decision:** a safe future selective reader needs role-specific seeking/preroll plus an input/work-based bound, not only a mask and a returned-packet timestamp gate. MP4 text subtitles are a promising narrow pilot; general MKV/bitmap subtitle and delayed-audio filtering is not accepted.

## 6. Decoder strategy: parallel frames versus parallel slices

The previous study varied thread count. This study separates **frame threading**, which pipelines different frames, from **slice threading**, which can work within a frame. FFmpeg explicitly documents the additional delay associated with frame threading [R3]. Actual configured count and active thread type are recorded; an advertised thread count is not assumed to imply useful parallel work.

Each file is decoded in full and through forward/backward five-frame seek windows. Six fresh-process samples per unpaced variant. Full decode elapsed/CPU work below is in milliseconds; RSS is the whole process's high-water estimate across opening, decoding and both seeks.

| Encoded slices/frame | Strategy | Full decode | CPU work | Peak RSS |
|---|---|---:|---:|---:|
| 1 | 1 thread, default | 992.812 | 992.155 | 26.4 MiB |
| 1 | 4 frame threads | 324.239 | 1,131.884 | 48.8 MiB |
| 1 | 4 slice threads | 995.341 | 995.268 | 26.6 MiB |
| 4 | 1 thread, default | 975.724 | 975.639 | 26.4 MiB |
| 4 | 4 frame threads | 316.995 | 1,126.305 | 49.1 MiB |
| 4 | 4 slice threads | 532.551 | 1,074.487 | 26.9 MiB |

Frame threading is the throughput winner here, at the cost of more CPU work and roughly 22 MiB higher process peak RSS. Slice threading helps the four-slice clip with much less extra resident memory and without increasing input packets required before first output. It offers no throughput benefit on the one-slice clip, despite the codec reporting slice-thread mode active.

These findings are specific to these H.264 files and the minimized Linux build. They do not select a HEVC, MPEG-2, VideoToolbox or Apple-device policy. For range context, one-slice frame-threaded full decode spans **276.046–385.045 ms**; default spans **925.527–1,061.095 ms**. Full ranges for every metric remain in the raw results.

All six separate checksum runs have identical selected pixels, timestamps, geometry and selected color/frame metadata within each file across the three strategies, including both seek windows: 1,140 retained frame observations. Exact representable target frames were found in these H.264 cases. These checks are not a codec-wide proof or a visible rendering comparison.

## 7. Pace the input and the startup conclusion changes

In the second decoder mode, video packet N may not be submitted earlier than `phase start + N * 16,667 microseconds`. This is a synthetic packet-availability schedule. File reads still occur normally; it is not real network delivery, an AVFoundation timebase, a display clock or an Illiquid output queue. Slow decoding can fall behind and catch up, and the schedule resets for each seek phase.

Three process samples per setting produce first decoded output at:

| Encoded slices/frame | 1 thread | 4 frame threads | 4 slice threads |
|---|---:|---:|---:|
| 1 | 41.920 ms | 83.448 ms | 41.866 ms |
| 4 | 41.995 ms | 83.461 ms | 38.767 ms |

The one-thread and slice-thread paths require **three submitted packets** before first output; four frame threads require **six**. Thus four frame threads roughly double the startup wait in this availability model, even though they finish the unpaced decode much sooner.

All strategies complete the paced full clip in roughly 2.99 seconds. This is not proof of zero displayed drops—there is no renderer. The four-slice paced CPU-work control is also unfavorable to a simplistic slice recommendation: **1,060.821 ms** for default, **1,122.448 ms** for four frame threads, and **1,196.793 ms** for four slice threads. Lower reorder memory and initial dependency do not guarantee lower CPU work or energy.

**Decision:** preserve production defaults. A future policy should distinguish steady playback, seek acceleration and sparse/slow input, assert the actual active route, and jointly measure deadline quality, CPU work, memory, and output fidelity. Thread count alone is not enough.

## 8. Retained fixes and integration evidence

The queue code in the prior local follow-up was reconciled with PR #5. Its existing revision check was kept, producer-only wake storms were removed, and the regression suite was added:

- `d6a1397a2352458a7b83ab32a76a0563e62c116a`: queue integration. Exact queue blob `ed52718d3bd42d1ebbd157343334be2bc6b6cc91`.
- `51eff7a04edf8314611a1f9ff171db5b901f6636`: `PacketQueueWakeupTests.swift`.

Nine selected Swift tests across the queue and prior experiment-guard suites passed in both release and debug in this environment. These are reruns, not new native playback measurements. The earlier queue performance numbers are not credited again in this report.

The macOS CI run for `51eff7a` completed the focused-core job and compiled the changed queue and native app sources, but the overall native job failed on an existing PR #5 test expression: a throwing `readPacket` call inside `#require` lacked the inner error handling. The test was repaired by evaluating the throwing read before the assertion (`7ca0f05c`). The workflow filter was extended to actually run `PacketOwnershipTests`, `PacketQueueWakeupTests` and `PlaybackBufferRegressionTests` (`699792a6`), without removing existing suites or changing permissions.

The corrected run **38975782035** at commit `699792a672bed91b936b436a5c60b3cda49f58a7` subsequently **passed both focused-core and native-lifecycle jobs**. The macOS native step built the app graph and ran the targeted regression filter, including the added playback suites. This closes the compilation/targeted-test gap for that code snapshot, not the visible-playback qualification gap. The separate publication/CI receipt records the tested commit and any later source-only research commit. The real-demux ownership test remains fixture-gated; it is not counted as executed when its environment variable is absent. Compiler/link success or synthetic packet tests would still not establish visible playback, A/V continuity, hardware recovery, energy or native footprint.

The full receipt checker validates **640 conditions**: process identities, actual ordering, library/thread modes, source hashes, complete frame counts, and preserved semantic differences. It does not require a speed win or label the known filtering differences acceptable. All three probes rebuilt from the packaged path and their smoke cases ran. AAC's 36-case reproduction matched the original results exactly. No subagents were used because no execution interface was available.

## 9. What to implement next—and what not to change yet

**Next extend the passing native CI to fixture-backed playback qualification.** The targeted queue/ownership/recovery filter has passed. Run fixture-backed demux lifetime, repeated seeks/source replacement and audio continuity on the locked SDK. Record actual active decoder, pixel route, frame presentation metrics, and memory-pressure behavior. Do not infer zero drops from absent measurements.

**For I/O, prototype a narrow role-aware reader rather than a global discard flag.** Start with MP4 text subtitles, preserving active cues across seeking and explicit input work/cancellation limits. Test queued-old/new generation work, large subtitle gaps, interleaving, corrupt inputs and sparse headers. Benchmark total open/probe/seek/read work, not only the cheap final scan. Matroska needs a different expectation: less packet allocation may help CPU even when all input bytes remain necessary.

**For decoding, qualify frame versus slice modes through real output queues.** Use multiple slice layouts, B-frame depths, codecs and high-bit-depth/4K inputs, not just these two H.264 clips. Measure steady deadlines and final seek landing separately. A low-reorder mode may help input-limited startup while a bounded frame-thread burst helps CPU-bound seeking. Dynamic switching would require a decoder-lifetime/recovery design; this pass does not implement it.

**For display, measure format-description/sample-buffer creation and retained surfaces on a Mac.** The existing presenter signposts and CoreMedia image-buffer matching API support a targeted format-description-reuse experiment [R4]. Keep HDR/color/geometry changes and renderer-owned lifetimes correct. No CoreMedia cache or renderer rewrite was added here without native evidence.

Global queue shrinkage, maximum automatic threading, a new persistent raw-media cache, and permanent per-frame logs are not supported by this pass. Keep throughput, first output, settled seek, actual display, logical bytes, physical I/O, CPU work, energy and resident ownership as separate measures.

## 10. Reproduction and evidence

`Benchmarks/PlaybackIOThreading/README.md` gives new-directory build and run commands. Probe C/header sources and primary drivers are byte-identical to the measured versions. The source-only bundle includes raw rows, summaries, manifests, commands, environment, queue rerun logs and receipt validation. It excludes generated media, compiled binaries and FFmpeg source copies; regenerate fixtures and build from the existing repository archive.

Primary receipts: `io-final/rows.jsonl`, `decode-modes-final/rows.jsonl`, and `audio-seek-verification.json`. Secondary files retain all ranges and mismatches. `RESULTS.json` is a compact index, not a replacement for raw evidence. The fixed-cohort checker may correctly flag a different decoder/encoder/library build; investigate rather than editing expected results merely to make it pass.

## References

Repository source references use the pinned main commit or the specifically named PR head: `Media/MediaSession.swift`, `Media/FFmpegDemuxer.swift`, `Media/FFmpegInputExecutor.swift`, `Media/MediaReadAheadGate.swift`, `Playback/PacketQueue.swift`, `Media/VideoDecoder.swift`, `Presentation/SampleBufferVideoPresenter.swift`, and `Sources/CFFmpeg/include/ffmpeg_shim.h`.

[R1] FFmpeg 8.1, AVStream discard: https://www.ffmpeg.org/doxygen/8.1/structAVStream.html  
[R2] FFmpeg 8.1, avformat_seek_file and active streams: https://www.ffmpeg.org/doxygen/8.1/group__lavf__decoding.html  
[R3] FFmpeg 8.1, AVCodecContext thread_type and frame delay: https://www.ffmpeg.org/doxygen/8.1/structAVCodecContext.html  
[R4] CoreMedia image-buffer matching: https://developer.apple.com/documentation/coremedia/cmvideoformatdescriptionmatchesimagebuffer(_:imagebuffer:)  
[R5] PR #5: https://github.com/Jagalite/illiquid/pull/5

External documentation motivates or constrains experiments; every numerical result above comes from this pass's receipts, not from those references.
