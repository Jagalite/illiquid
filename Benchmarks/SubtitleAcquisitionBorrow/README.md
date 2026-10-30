# Subtitle acquisition packet borrowing

This experiment compares the compressed-packet copy in the original
`FFmpegDemuxer.activeSubtitlePackets` acquisition check with synchronous packet
borrowing. It covers both PGS and DVB subtitles. The baseline is main at
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`.

The runner compiles exact production declarations against real FFmpeg:

- the complete `FFmpegPacket` owner;
- both complete acquisition parser enums;
- the complete candidate packet adapter;
- the original rational, seconds conversion, error handling, and required C
  helpers.

It excludes the application, demuxer execution, CoreMedia-only methods,
CoreGraphics rendering, and VideoToolbox helpers. It verifies the demuxer's
actual call sites against the driver adapters and records every full source and
extracted source hash. Full native integration is a separate workflow step.

## Run

Use Swift 6.3.2 or newer, Python 3.9 or newer, and FFmpeg headers plus real
`libavcodec`/`libavutil` libraries. Fetch the pinned baseline if the checkout is
shallow. Submit compiler work through Kyoto when the shared queue is available;
otherwise explain its absence before direct builds, as required by `AGENTS.md`.

```sh
python3 Benchmarks/SubtitleAcquisitionBorrow/run.py \
  --ffmpeg-prefix /opt/homebrew/opt/ffmpeg \
  --pairs 6 --target-ms 150 --minimum-ms 50 \
  --output /tmp/subtitle-acquisition-borrow
```

On Linux, supply the installed FFmpeg prefix and optionally `--swiftc` with an
absolute compiler path. Add `--allocations` to count allocation requests in
separate processes using the existing glibc allocation meter. `--tests-only`
builds all four baseline/candidate debug/release executables and verifies their
complete traces without timing. Output directories must be new or empty.

## What is checked

The deterministic corpus contains 2,222 cases, including every PGS state byte,
all DVB state-byte/page-selection combinations, legal maximum segment lengths,
truncations, misleading nested headers, malformed prefixes and tails, missing
and nonpositive payloads, deterministic random bytes, and mutated compositions.
Authored expectations supplement independent baseline/candidate trace equality.
The driver also checks unchanged packet pointers, bytes and native reference
counts, and immediate release of the Swift packet owner.

Eight timing workloads rotate sixteen actual packets. They cover tiny PGS/DVB
controls and approximately 4 KiB, 64 KiB, and 256 KiB packets, alternating normal
and acquisition states and placing the composition before or after the object
segments. Object bodies are deterministic synthetic bytes; they are not claimed
to be decodable subtitle images. Every timed cycle must produce an independently
specified checksum of 1,304.

Six fresh-process pairs alternate baseline/candidate and candidate/baseline.
Each variant is independently calibrated, and durations are normalized by its
packet count. Fixture allocation, warmup and JSON output are outside timing.
Both process CPU and wall time must exceed the requested duration floor. Every
observation is retained; a short observation rejects the cohort.

Optional allocation observations use 4,096 checks per fresh process and three
observations per variant/workload. The meter is enabled only around the scan
loop. Timed processes never preload it, and inherited allocation interposers
are rejected. The counters measure successful `malloc`, `calloc`, and `realloc`
requests and their requested sizes. They do not measure retained or peak heap,
RSS, GPU memory, macOS physical footprint, or every native allocator API.

## Evidence

The runner emits full acquisition traces, source and binary hashes, compiler
and linked-library information, calibration pilots, raw measurements, paired
summaries, allocation observations when requested, command logs, and a
completion receipt. Failed attempts keep their diagnostics.

See [the research report](../../Documentation/SUBTITLE_ACQUISITION_BORROW_PERFORMANCE.md)
for measured results and qualification limits. The dedicated
[native workflow](../../.github/workflows/subtitle-acquisition-borrow.yml) also
builds the full application/test graph and runs acquisition, bitmap decode,
paused-seek, crop, and packet-ownership tests with generated PGS/DVD/DVB media.
