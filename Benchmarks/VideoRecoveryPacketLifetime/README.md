# Video recovery GOP lifetime at successful EOF

## Question

Does the recovery packet buffer retain the final compressed GOP after a
successful decoder drain, even while the session remains alive? Can that
ownership be retired without changing error recovery, generation isolation,
or the lifetime of other packet owners?

The production buffer retains at most 512 packets and 32 MiB of payload. The
baseline is `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`. Its complete
`FFmpegPacket.swift`, including `VideoRecoveryPacketBuffer`, is frozen under
`baseline/`; the runner checks both its Git blob identity and SHA-256 hash.

## Reproduce the portable ownership experiment

Requires Linux, Swift 6.1 or newer, Python 3, a C compiler, make, and pkg-config.
Build the repository's verified FFmpeg 8.1.2 source archive and then run:

```sh
bash Benchmarks/DeinterlacerEOFMemory/build-linux-ffmpeg.sh /tmp/video-recovery-ffmpeg
python3 Benchmarks/VideoRecoveryPacketLifetime/run.py \
  --ffmpeg-prefix /tmp/video-recovery-ffmpeg \
  --output /tmp/video-recovery-lifetime
```

Use new SDK and result directories. When Kyoto is available, submit build work
through it as required by `AGENTS.md`. On a hosted runner without Kyoto, state
that limitation and run these isolated builds sequentially.

The runner compiles the exact old and new production packet-owner source in
debug and release with warnings treated as errors. It reuses the narrow
Foundation-only support declarations from
`Benchmarks/PlaybackPipeline/PacketProbeSupport.swift`. The FFmpeg APIs and
public structures come from the real pinned development headers; packet,
reference, allocation, and release operations use the real FFmpeg libraries.
Four C helpers are extracted unchanged from the production shim. Header and
runtime library versions must agree.

The new production method wraps a synthetic drain closure in this probe. The
baseline executes the same closure without EOF retirement, matching its old
boundary behavior. Neither variant's production owner is rewritten or modeled.

## Measurements and controls

Each payload comes from `av_mallocz` and `av_buffer_create`, with a free callback
that records actual destruction. Fixture creation ends before the drain so
the recovery buffer is its only packet owner in the three successful cases:

| Final GOP | Packets | Payload bytes |
| --- | ---: | ---: |
| Small | 4 | 4,096 |
| Medium | 16 | 1,048,576 |
| Maximum bounded GOP | 512 | 33,554,432 |

Payloads must remain alive during the drain. The baseline must retain them
afterward while the buffer remains alive; the candidate must release them.
Explicit reset then proves that every baseline allocation also releases
exactly once. Repeated successful EOF checks idempotence.

Six controls run against both variants:

- A throwing decoder drain preserves replayable recovery packets.
- A drain that throws `CancellationError` preserves them and rethrows the error.
- A stale-generation EOF preserves the current generation's GOP.
- A generation change from inside the drain preserves the new GOP.
- An external native `AVPacket` clone keeps its bytes valid after retirement;
  deallocation follows the last real native owner.
- A fresh GOP after a seek remains replayable after the prior EOF.

The runner rejects missing controls, missing release callbacks, double
destruction, wrong retained byte counts, and differing debug/release results.
It retains source and binary hashes, compiler/library identities, SDK build
receipts, all commands/logs, raw observations, and a compact summary.

## Scope

This proves a component ownership boundary. The probe does not run
`MediaSession`, decode media, or qualify end-to-end macOS EOF/recovery behavior.
The cancellation control covers throwing cancellation; it does not simulate a
decoder that returns normally after cancellation. Run the native
`VideoRecoveryPacketLifetimeTests` and existing playback/recovery suites on
the supported macOS SDK as the integration gate.

Reported bytes are the requested tracked payload and padded backing allocations.
They exclude allocator overhead, decoder reference pictures, renderer storage,
and process RSS. Other real owners may legitimately keep the allocation alive,
as the native-clone control demonstrates. The experiment makes no CPU-time or
whole-player memory claim.
