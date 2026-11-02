# Independent validation of video recovery packet lifetime at EOF

**[Measured results and qualification status](RESULTS.md)** · [Raw evidence](evidence/linux)

This study builds on [PR #172](https://github.com/Jagalite/illiquid/pull/172).
It contributes independent control-flow and native-buffer evidence, plus decoded-output
ownership tests. There are no additional production changes relative to that PR.
The candidate packet-owner source includes its generation-checked
`releaseAfterDrain(generation:)` method; the baseline owner and session methods
come from the original main commit below.

The video decode worker records a bounded compressed GOP for software decoder
recovery. Before this change, normal EOF leaves the final GOP owned by
`VideoRecoveryPacketBuffer` until seek, stop, or another reset. The configured
limits are 512 packets and 32 MiB of compressed payload.

The candidate releases this buffer immediately after `VideoDecoder.drain` returns
normally and before the existing output EOS queue push. Thrown errors, including
cooperative cancellation, skip the reset. The patch follows the existing EOS boundary; it does not introduce
new native decoder completion guarantees or alter presentation recovery.

## Reproduce

On macOS, use macOS 26, the repository's pinned FFmpeg 8.1.2 SDK, and a Git checkout containing
baseline commit `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`:

```sh
python3 Benchmarks/VideoRecoveryEOFMemory/run.py \
  --output /tmp/illiquid-recovery-eof --pairs 2

swift test --force-resolved-versions -c release --jobs 2 --no-parallel \
  --filter 'VideoRecoveryDecodedOutputLifetimeTests|VideoRecoveryPacketLifetimeTests|PacketOwnershipTests|VideoScratchFrameLifetimeTests'
```

Linux can run the same ownership experiment against the same FFmpeg source:

```sh
ILLIQUID_FFMPEG_BUILD_JOBS=4 bash Benchmarks/DeinterlacerEOFMemory/build-linux-ffmpeg.sh \
  /tmp/illiquid-recovery-eof-sdk
python3 Benchmarks/VideoRecoveryEOFMemory/run.py \
  --sdk-prefix /tmp/illiquid-recovery-eof-sdk \
  --output /tmp/illiquid-recovery-eof-linux --pairs 2
```

The SDK builder verifies the included 8.1.2 archive against both corresponding-source
manifests. The SDK and experiment destinations must be new. Linux compiles six
complete production Swift files unchanged, extracts the exact rational/seconds
declarations from MediaTime while omitting unused CoreMedia APIs, and extracts the
seven required C shim helpers verbatim. The three session methods, native packet
operations, ownership counter, and scenarios are unchanged. Only the controlled
harness's platform imports are adapted. Linux results do not qualify the macOS app.

Use a new output directory. When Kyoto is available, the component runner submits
each build through the shared queue and retains its show/wait/logs receipts.
Submit native Swift test compilation through Kyoto on hosts where it is available.
On ephemeral CI hosts without Kyoto, the workflow explicitly reports the fallback
and builds serially in isolated checkouts.

## What is measured

The runner compiles complete, unchanged production packet/buffer/queue/generation
sources, using each variant's own complete FFmpegPacket source. It extracts the exact `decodeVideoPacket`, pending-replay transfer,
and `videoDecodeLoop` methods from baseline and candidate MediaSession sources.
Only surrounding decoding and presentation are controlled by the harness.

Each fresh packet is allocated by `av_new_packet`. The probe transfers its sole
existing native buffer reference into a final-release callback. It does not keep
an extra observer reference, copy the packet bytes, or infer destruction from
Swift wrapper counts. It records real backing allocation lifetime before drain,
at output EOS enqueue, after replay/consumer release, and after cleanup.

Byte counts are `AVBufferRef.size`, including FFmpeg's input padding. They exclude
AVPacket/AVBufferRef metadata and allocator overhead. These are native backing
allocation ownership measurements, not whole-player RSS, physical footprint,
GPU memory, playback throughput, or measurements of typical media GOP size.

The synthetic small workload contains four 256 KiB packets (1 MiB payload). The
budget workload contains 512 64 KiB packets (32 MiB payload). Both stay within the
existing recovery-buffer limits; the budget workload reaches both limits.

## Behavioral gates

Both debug and release builds run nine scenarios in two fresh-process AB/BA pairs:
empty input, small/budget GOPs, repeated EOF, failure after partial output,
cancellation after partial output, stale EOF, an independent native buffer owner,
and a later playback generation.

The runner compares complete ordered output receipts, timestamps, generations,
EOS markers, failure classification, and replay counts. It verifies that packet
ownership survives until the drain returns and that cleanup respects independent
native references. Every allocation must eventually be freed exactly once.

The old implementation must also fail the candidate EOF-release assertion with
exit 73 and `EOF_RELEASE_REGRESSION`; a crash, compile failure, or arbitrary
nonzero exit does not qualify as a negative control. The candidate must pass the
same assertion.

`VideoRecoveryDecodedOutputLifetimeTests` separately uses the actual software VideoDecoder
and valid raw BGRA packets. It verifies that recovery cleanup preserves decoded
pixels and timestamps, respects an independent native packet clone, and leaves
cancelled-drain input available for replay. It reuses the existing scratch-frame
fixture. These tests complement the controlled production-loop experiment.

## Evidence and limits

The workflow retains full input and extracted source bytes/hashes, toolchain/SDK
versions, commands, binary hashes, every complete JSON observation, and paired
comparisons. The compact persistent evidence includes complete canonical output
receipts and all ownership observations; the CI artifact also contains build and
native test logs.

The controlled loop is synchronous and does not measure real-time presentation or
scheduler concurrency. Native release tests build the full application graph.
Visible UI, hardware decode, and end-to-end playback memory are separate
qualification scopes.
