# Bitmap subtitle acquisition during seeks

This experiment compares acquisition checks in `FFmpegDemuxer.activeSubtitlePackets`.
The existing path copies each selected PGS/DVB packet into `Data` before scanning
segment headers. The candidate uses a scoped, non-owning `Data` view while keeping
the real `FFmpegPacket` alive. Both existing parsers and packet ownership remain
unchanged. Foundation may copy tiny inputs internally; this is not a universal
zero-allocation claim.

## Reproduce

On macOS with Swift 6.1+ and the repository's pinned native SDK:

```sh
python3 Benchmarks/BitmapSubtitleAcquisition/run.py --tests-only \
  --output /tmp/bitmap-acquisition-tests
python3 Benchmarks/BitmapSubtitleAcquisition/run.py --pairs 8 --target-ms 180 \
  --output /tmp/bitmap-acquisition-timing
```

Use a new/empty output directory. The runner requires the baseline Git history
(`git fetch --unshallow` for a shallow clone). It does not download dependencies.
When Kyoto is available, submit the whole command through its shared queue as
required by `AGENTS.md`; CI reports its absence and builds serially.
`--swiftc` and `--ffmpeg-prefix` select existing tools and dependencies.

## Source and correctness contract

The baseline is `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`. The runner checks
its ancestry and original demuxer/parser Git blobs, saves the full source files,
and derives the baseline adapter from the actual old call-site expression.
It extracts the candidate's complete packet helper declaration from the current
demuxer. The complete, unchanged PGS/DVB parser declarations are extracted from
`BitmapSubtitleTimeline.swift`; unrelated subtitle geometry is excluded.

Both variants compile the complete production `FFmpegPacket`, `MediaTime`,
`FFmpegError`, `PacketQueue`, `FixedRingBuffer`, and CFFmpeg module against real
FFmpeg. Shared dependencies must match the baseline byte-for-byte. No packet,
parser, C API, or lifetime behavior is mocked.

The production component and common client are compiled separately, with
`-enable-testing` for internal access and no cross-module optimization.
Complete per-input Boolean decisions and input hashes must match in debug and
release. Authored expectations cover all PGS acquisition/epoch flag bytes and
DVB state/page combinations, truncated headers and bodies, oversized lengths,
embedded header-like payloads, early successful returns, null/nonpositive
payloads, deterministic random bytes, and mutated compositions.

The native workflow separately builds the application/test graph and executes
packet ownership, the new acquisition tests, and fixture-backed PGS/DVD/DVB seek
regressions through the repository's receipt-validating Swift Testing runner.

## Timing contract

Twenty-two workloads cover both formats, tiny end/ordinary/acquisition controls,
4 KiB/64 KiB/256 KiB synthetic object payloads, acquisitions before and after
large payloads, and mixed accepted/rejected packets. Every workload rotates
sixteen native packets. Larger payloads use multiple legal UInt16-length
segments. Payload contents are synthetic and do not establish pixel decoding.

Eight fresh-process pairs alternate AB and BA order. Each process warms 4,096
calls, then records process CPU and monotonic wall time while consuming every
decision. Each variant is independently calibrated to complete cycles of the
same input distribution, avoiding excessive baseline durations when copying is
much slower. Timed checksums, all sixteen decisions, payload sizes, and warmup
receipts must agree. At least 60 ms of CPU and wall time is required per sample;
short observations are retained and fail qualification. No observations or
controls are subtracted or discarded.

Receipts retain full source snapshots, build commands, compiler/host/library
and binary hashes, all correctness traces, calibration pilots, raw observations,
paired ratios, and summaries. GitHub Actions also emits compact result records
in its logs and retains the complete artifact for 14 days.

## Interpretation

These are native acquisition-component measurements during seek reconstruction.
They exclude demux I/O, actual packet-frequency distributions, FFmpeg decoding,
subtitle rendering, UI latency, whole-seek time, player CPU, memory residency,
and energy. Results and their limitations will be recorded after validation.
