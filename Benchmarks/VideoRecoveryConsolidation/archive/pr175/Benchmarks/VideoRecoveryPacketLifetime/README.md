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

## Finding and change

`MediaSession.decodeVideoPacket` records compressed input in this recovery
buffer. The final GOP used to remain referenced after the video worker drained
the decoder and queued EOS, until a later seek, stop, or session destruction.
The worker and session can remain alive while playback sits at the end.

The candidate wraps the existing decoder-drain call in
`retireAfterSuccessfulDrain`. A normal return releases the buffer's packet
references and array capacity. A throwing failure or cancellation keeps the
complete GOP available to the existing recovery path. Draining happens outside
the buffer lock; the retirement checks the generation under that lock so a
finishing old drain cannot discard packets belonging to a newer seek.

“Successful” here means normal return from the player's existing drain-to-EOS
boundary. The patch does not change the decoder's handling of EOF, EAGAIN, or
tolerated software errors. It also does not change packet admission bounds,
decoding, frame delivery, or the ordinary seek/replay path. Independent packet
and frame owners retain their own storage. FFmpeg's
[reference-counted buffer contract](https://www.ffmpeg.org/doxygen/8.1/group__lavu__buffer.html)
releases native data only after the last reference disappears.

## Measured ownership results

The [portable CI experiment](https://github.com/Jagalite/illiquid/actions/runs/40639152416/job/122652965238)
passed using Swift 6.4.1 on Ubuntu 24.04 and the repository's verified FFmpeg
8.1.2 source. The exact baseline and candidate owners each passed 48 checks in
debug and release; observations agreed between build configurations.

| Final GOP | Payload still owned after drain, baseline | Candidate |
| --- | ---: | ---: |
| 4 packets, 4 KiB | 4,096 bytes | 0 bytes |
| 16 packets, 1 MiB | 1,048,576 bytes | 0 bytes |
| 512 packets, 32 MiB | 33,554,432 bytes | 0 bytes |

These fixtures make the recovery buffer the only packet owner. No tracked
payload was freed during the drain, and every allocation eventually released
exactly once. The separate native-clone control proves that another real owner
can legitimately extend the payload lifetime after retirement.

[Raw observations, commands, provenance, and logs](evidence/ubuntu/) are
committed with the study. This is a reduction in retained recovery-buffer
ownership, not a measurement of total player RSS or an asserted CPU speedup.
The retained run covers the ownership probe at commit `9da2b2ed`; the production
owner has the same source hash in the subsequent test additions. The exact-suite
and real-session gates added afterward have their own CI results and must not
be inferred to have passed from this earlier receipt.

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

Before the ownership probes, the runner stages an isolated Swift package and
executes the exact, unchanged `VideoRecoveryPacketLifetimeTests.swift` in debug
and release: ten test functions, including three payload-size arguments, give
twelve cases per configuration. The package contains the same candidate owner,
support declarations, and real FFmpeg header module. It uses the compiler's
bundled Swift Testing library with no external dependencies, and keeps all
SwiftPM build/cache files under the result directory's `build/`. The runner
requires the completion markers for all functions and all three size arguments
and records the test source hash and full test logs.

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
decoder that returns normally after cancellation. Although the exact packet
lifetime regression suite also runs here, the existing playback/recovery suites
still need the supported macOS SDK as the integration gate.

The workflow also builds the complete macOS application graph and runs
`VideoRecoveryPacketSessionLifetimeTests` with a required synthetic H.264
fixture. That test observes real session packet owners through decoder drain
and frame submission, before stopping the session. It fails if the fixture is
missing. A queued job is not executed integration evidence; consult the CI run
for its status. No live UI, visible-frame, or physical-device performance claim
is made by this study.

Reported bytes are the requested tracked payload and padded backing allocations.
They exclude allocator overhead, decoder reference pictures, renderer storage,
and process RSS. Other real owners may legitimately keep the allocation alive,
as the native-clone control demonstrates. The experiment makes no CPU-time or
whole-player memory claim.
