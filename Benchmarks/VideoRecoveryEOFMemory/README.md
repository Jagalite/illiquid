# Video recovery GOP lifetime at EOF

The session records one bounded compressed-video GOP so a failed decoder can
replay it into a software replacement without disturbing audio. On the pinned
baseline, a successful video drain queues EOF but leaves that replay buffer
populated until seek, stop, a new keyframe, or another reset.

This study releases only the completed generation's replay ownership after
the session's existing nonthrowing drain path. A throwing drain bypasses the
release. An outer running/generation check and an inner locked generation
check protect seek/stop races. The byte limit (32 MiB), packet limit (512),
decoder policy, queue capacities, and output paths are unchanged.

Baseline: `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`.

## Qualification

Use the pinned native SDK from `BuildInputs/native-sdk.json`, macOS 26,
Xcode 26.6, and the repository's resolved Swift dependencies. The dedicated
`video-recovery-eof-memory.yml` workflow installs the verified inputs and runs
these commands serially in an isolated checkout:

```sh
python3 Benchmarks/VideoRecoveryEOFMemory/measure.py \
  --pairs 2 --output /tmp/video-recovery-eof-component

python3 Benchmarks/VideoRecoveryEOFMemory/run_native.py \
  --output /tmp/video-recovery-eof-native
```

Both output directories must be new or empty. Follow `AGENTS.md`: use Kyoto
when available. The hosted runner explains that the shared queue is unavailable
before its direct builds. Do not run `run_native.py` in a working checkout
containing edits: it temporarily stages baseline/candidate source and probes,
builds serially, and restores the original files in `finally`.

Results must come from completed native runs; the source analysis and expected
ownership changes alone do not establish a measured player improvement.

## Component experiment

`measure.py` compiles the complete production `FFmpegPacket`, `MediaTime`,
`FFmpegError`, `PacketQueue`, and `FixedRingBuffer` sources with the complete
CFFmpeg shim. It requires all shared dependencies to match the baseline and
permits only the exact `finish(generation:)` insertion in the packet file.

The baseline component operation is explicitly a no-op, representing the
existing EOF buffer lifetime. The candidate calls the actual new method.
This component experiment does not execute decoder drain or MediaSession;
the second experiment below covers that integration.

`CLifetimeProbe` allocates packets through `av_new_packet`, moves each sole
original AVBuffer reference into a final-release wrapper, and adds no observer
reference. The wrapper's last-reference callback unreferences the original
allocation and counts released buffers, payload bytes, and declared buffer
extents. This detects final release of the tagged native allocations.

Seven cases cover an empty buffer, a 120-packet 7.5 MiB GOP, the exact 32 MiB
byte limit, the exact 512-packet limit, a held native packet clone, stale
generation completion, and the existing explicit-reset control. Two balanced
baseline/candidate pairs in both debug and release produce 56 fresh-process
observations. The held clone must retain intact payload until its own final
release. Replay metadata, order, complete payload checksums, and final cleanup
must satisfy the assertions.

The measurements exclude packet headers, the meter's bookkeeping, allocator
metadata/caching, decoder-owned allocations, decoded frames, GPU resources,
and process RSS. No playback-speed or whole-player RSS improvement is claimed.

## Actual native session experiment

`run_native.py` first compiles the ordinary candidate application/test graph
and executes the new packet lifetime tests, existing packet ownership tests,
and three existing video decoder recovery tests. The fixture-dependent tests
are supplied generated media and must actually run.

It then stages the original and changed production files sequentially,
appending the same harness-only probes to each. It removes the candidate-only
unit-test file while compiling the baseline. The probes inspect the locked
replay buffer and consume the prepared video queue; production code has no
new diagnostic storage or public test hooks.

A four-frame H.264 fixture with B-frame reordering drives the real session's
demux/decode workers through `prepareForCommit()`. The session remains alive.
The test waits for four frames plus the EOF marker, checks recovery ownership,
consumes all frames, retains one output, seeks to zero, and repeats. It checks:

- Baseline retains a nonempty recovery GOP at EOF; candidate retains none.
- Complete active BGRA pixel hashes, exact timestamps/durations, and relevant
  frame metadata match before/after seek and across baseline/candidate.
- The held first-generation frame survives seek and shutdown unchanged.
- Both sessions shut down cleanly and release recovery ownership on stop.

The session's packet/byte probe measures recovery-buffer ownership; it is
separate from the component's final-release allocation measurement. Renderer
consumption and live UI behavior are not qualified by prepared-session output.

A thrown drain skips the release by control flow. There is no synthetic
production drain callback added solely to test this change. The independent
generation tests and existing decoder recovery tests protect replay behavior;
they should not be described as fault injection into the session's EOF call.

## Evidence

Each runner retains JSON receipts, complete source/probe snapshots, command
arguments and exit statuses, source/log hashes, and raw logs. The component
also records executable hashes and all individual lifetime observations.
The native runner retains the generated fixtures and output receipts.

All commands check exit codes. The native runner also requires a successful,
nonzero Swift Testing receipt and exact output parity. The workflow uses
`bash` with `pipefail` and uploads evidence even on failure.

FFmpeg's primary ownership and drain contracts:
[AVBuffer reference counting](https://www.ffmpeg.org/doxygen/8.1/group__lavu__buffer.html)
and [decoder send/receive lifecycle](https://www.ffmpeg.org/doxygen/8.1/group__lavc__encdec.html).
