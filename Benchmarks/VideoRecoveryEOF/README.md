# Video recovery GOP lifetime at EOF

## Result and qualification

The compressed-video recovery buffer kept its final GOP after decoder drain
completed. This change releases that recovery ownership at the existing
successful-drain boundary, while the session and its decoded frames remain
alive.

The component experiment uses actual production Swift packet code and real
FFmpeg reference-counted allocations. On Linux, the candidate releases all
tracked recovery-owned allocations at EOF when no independent owner remains.
The maximum admitted synthetic GOP goes from **32 MiB of retained payload to
zero**. This is a bounded component-retention improvement; actual media savings
depend on the final GOP and other owners.

The native macOS job is queued at publication. The PR stays a draft until the
complete application graph, the new packet tests, and the actual session
comparison execute successfully.

## Production change

Only two production files change:

- `Sources/IlliquidNativePlayback/Media/FFmpegPacket.swift` adds
  `VideoRecoveryPacketBuffer.releaseAfterDrain(generation:)`. It checks the
  stored generation and clears ownership under the existing buffer lock.
- `Sources/IlliquidNativePlayback/Media/MediaSession.swift` calls it after
  `try videoDecoder.drain(...)` returns and before publishing the frame EOF
  marker.

The existing buffer bounds remain 512 packets and 32 MiB of packet payload.
Admission, keyframe replacement, overflow handling, and recovery replay are
unchanged.

### Why this boundary is safe

Demux EOF is too early: delayed video output and decoder recovery may still need
the compressed input. Cleanup occurs only after the existing drain returns
without throwing. A throwing drain follows the unchanged recovery path with its
GOP retained. Some decoder errors are already intentionally handled inside the
decoder; this change follows the existing no-throw completion contract, without
adding a new assertion that every underlying codec returned a particular code.

A seek may advance the generation while an old drain is completing. Checking and
clearing under the buffer's own lock prevents old EOF work from clearing or
relabeling a newer generation's GOP. Repeated completion is harmless.

The cleanup precedes `videoFrames.push(.endOfStream(...))`, which can block on a
full output queue. Decoded frames retain their own output storage. An independent
`AVPacket` clone or a caller holding transferred replay packets keeps the shared
native storage alive until its own reference is released.

FFmpeg's [packet ownership API](https://ffmpeg.org/doxygen/trunk/group__lavc__packet.html)
and [buffer ownership API](https://ffmpeg.org/doxygen/trunk/group__lavu__buffer.html)
describe those reference-counting semantics. The tests exercise them with real
allocations and final-free callbacks.

## Measured component results

Baseline: `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`.

Qualified code and harness:
`b162b972b6e13ccfbe08bb6462275f4143dc2077`.

[Qualification run](https://github.com/Jagalite/illiquid/actions/runs/40639569144).
The Linux job runs on Ubuntu 24.04 with Swift 6.4, libavcodec 60.31.102,
and libavutil 58.29.100. Exact versions, source and binary hashes, library
inventory, commands, and raw observations are retained in
[`evidence/linux/component/receipt.json`](evidence/linux/component/receipt.json).

| Final retained GOP | Baseline payload after EOF | Candidate payload after EOF | Baseline requested native storage | Candidate requested native storage |
|---|---:|---:|---:|---:|
| Empty | 0 B | 0 B | 0 B | 0 B |
| One 64 KiB packet | 65,536 B | 0 B | 65,600 B | 0 B |
| 120 × 64 KiB packets | 7,864,320 B (7.5 MiB) | 0 B | 7,872,000 B | 0 B |
| 512 × 64 KiB packets | 33,554,432 B (32 MiB) | 0 B | 33,587,200 B | 0 B |
| Replacement GOP, five packets | 327,680 B | 0 B | 328,000 B | 0 B |

Requested native storage includes the 64 bytes of FFmpeg input padding in each
tracked allocation. It excludes allocator overhead, packet headers, side data,
decoder and renderer pools, and process RSS. Every tracked allocation is freed
exactly once. The 32 MiB row is the admitted boundary case, not an estimate of a
typical video's final GOP.

The controls require:

- An independent native clone still holds its 64 KiB payload after EOF; its
  checksum remains unchanged, and final storage destruction waits for the clone.
- Stale-generation completion preserves all four newer-generation replay packets.
- Pre-EOF recovery returns the same eight packets, properties, and checksums.
- Keyframe replacement, explicit reset, empty completion, and repeated completion
  retain their original behavior.

All 16 fresh-process observations agree within each variant across debug
(`-Onone`) and release (`-O`). Each observation covers eight scenarios. ABBA
then BAAB ordering is used for each configuration. There is no latency, decoding
throughput, UI responsiveness, or whole-player memory claim.

## What the experiment executes

`run.py` compiles the complete baseline/candidate `FFmpegPacket.swift` and
`FFmpegError.swift`. It extracts unchanged portable declarations from the
production time/queue code and seven C shim helpers, then verifies those support
inputs are identical between variants. No packet or allocation APIs are mocked.

The EOF adapter contains the exact production statements after the drain emitter
closes and before the video EOF marker is pushed: no statement for the baseline,
and the new cleanup call for the candidate. The component driver supplies that
successful-drain boundary; it does not execute a video decoder.

`Driver.swift` allocates payload storage with `av_mallocz`, creates real
`AVBuffer` references with a counted final-free callback, and creates actual
`FFmpegPacket` owners. Observers keep counters and weak references only.
Independent replay lifetimes are explicitly enclosed in `withExtendedLifetime`.
A live-buffer result means the corresponding callback has not executed; a zero
result is backed by observed callbacks, not inferred from array counts.

## Native integration and regression gate

The workflow also prepares the repository's pinned native SDK and builds the
complete app/test graph on macOS 26. This job is pending runner availability;
the following are authored checks, not reported executions.

`VideoRecoveryEOFLifetimeTests` observes the actual `MediaSession` demux/decode
workers using a generated one-frame H.264 fixture and weak references to its real
demuxed packets. Presentation stays inactive, so a decoded frame and EOF marker
remain queued. The same observation test is run against baseline and candidate
for initial EOF and two subsequent seeks. It requires one baseline-retained packet
and zero candidate-retained packets while the session is prepared and alive,
then zero packet owners after shutdown.

The workflow temporarily stages only the two baseline production files for that
comparison, removes the candidate-only unit suite during the baseline build,
and restores the candidate with an exit trap. Receipt assertions reject skipped
or missing session observations.

Six `VideoRecoveryPacketLifetimeTests` exercise native destruction, repeated
completion, stale seek generations, independent clones, buffer reuse, and
transferred replay ownership. Existing `PacketOwnershipTests` and
`PlaybackBufferRegressionTests` run alongside them. The native runner rejects
zero executed tests and retains JUnit receipts.

These checks cover the changed ownership boundary. They do not qualify live
window rendering, hardware-specific decode recovery, or physical-device RSS.

## Reproduction

Use Swift 6, Python 3, `pkg-config`, and development headers/libraries for
`libavcodec` and `libavutil`. On Ubuntu these are supplied by
`libavcodec-dev libavutil-dev pkg-config`. On macOS select the pinned native SDK
and runtime library paths before running:

```sh
python3 Benchmarks/VideoRecoveryEOF/run.py \
  --pairs 2 --output /tmp/illiquid-video-recovery-eof
```

The output directory must be new or empty. The runner fails on unexpected
ownership, changed replay data, damaged clone data, repeated native frees,
SDK/runtime mismatch, or nondeterministic observations. `receipt.json` sets
`complete: true` only after every comparison passes.

Follow `AGENTS.md`: submit builds through Kyoto when available, preserving the
command and environment, then inspect the job's status, logs, and completion.
The isolated hosted CI jobs first verify that Kyoto is unavailable and report
that limitation before direct compilation.

For the complete macOS session comparison, run the
[`video-recovery-eof-lifetime.yml`](../../.github/workflows/video-recovery-eof-lifetime.yml)
workflow. It generates and validates the required fixture, runs both session
variants, verifies their receipts, and uploads source/measurement evidence.
