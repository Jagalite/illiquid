# Playback pipeline: packet ownership experiments

Start with `Documentation/PLAYBACK_PIPELINE_RESEARCH.md`. This is a selected-source experiment, not a full player benchmark. It changes neither decoder preference nor buffering policy. The baseline is merged main `8c3cc3d4008d5d1b8d436bcf2d51d891382b6548`.

## Real FFmpeg C demux comparison

Requires Python 3.10+, a C compiler and FFmpeg CLI with libx264/AAC/MPEG-2/MP2 encoders. Installed FFmpeg development headers and pkg-config are preferred (major 61 or 62). The tested fallback is Linux FFmpeg 7.1.5, libavcodec 61.19.101: its public AVPacket declarations are version-gated; the product never uses this bridge. Other versions without SDK headers are rejected.

```sh
python3 Benchmarks/PlaybackPipeline/run.py --output /tmp/illiquid-packet-parity --tests-only
python3 Benchmarks/PlaybackPipeline/run.py --output /tmp/illiquid-packet-timing --repeats 9 --rounds 100
```

Use a new or empty output directory. The driver generates isolated eight-second fixtures, checks packet and side-data parity across three variants, rotates their process order, writes every completed observation, and records source/binary/fixture hashes. It does not download dependencies, change installed preferences, read user media, or run playback. Do not run competing benchmark cohorts simultaneously.

The 100 scans are unpaced, warm-cache demux work. Open/probe/seek is recorded separately; there is no native Swift executor, decoding or display. Explicit packet-header counts are not all allocations or RAM usage. The report retains the slower MPEG-TS result and overlapping ranges. Regenerated fixture hashes may differ by FFmpeg build or container metadata; compare variants against the same generated files in one cohort.

## Actual Swift packet owner and real FFmpeg buffer lifetime

This Linux-only probe requires Swift 6, libavcodec.so.61 and libavutil.so.59 at the version above. It compiles the exact baseline/candidate packet owner with public C declarations and narrow supporting value types instead of CoreMedia. Native image/decoder/display behavior is not modeled or qualified.

```sh
bash Benchmarks/PlaybackPipeline/run-packet-probe.sh /tmp/illiquid-packet-owner-tests
```

The output directory must not exist. Both debug and optimized builds use warnings-as-errors. Results and compiler logs are retained. Baseline `oversized_replay_count: 1` is the reproduced defect, not the desired outcome; the candidate must return zero. Baseline source Git blob identity is checked. The buffer callback verifies release after the last real reference, not a simulated owner counter.

## Native tests and merge gate

On a supported Mac with the repository's locked SDK:

```sh
swift test -c release --filter PacketOwnershipTests
ILLIQUID_PACKET_OWNERSHIP_FIXTURE=/path/to/owned/fixture.mkv \
  swift test -c release --filter PacketOwnershipTests
```

Also run the complete release/native suite and architecture check. Compare visible playback, seek/recovery and teardown against the baseline. Never interpret syntax parsing or the Linux packet bridge as a macOS SDK build. Five tests are unconditional and the sixth demux lifetime test is explicitly fixture-gated. The tests allocate a little over 32 MiB for the recovery boundary cases.

## Recorded results

`RESULTS.json` contains all 81 raw timing rows and their column schema, fixture hashes, execution scope and packet-receipt checks. Units are nanoseconds unless the field says otherwise; each row has 100 scans and retention 96. Variant meanings: baseline allocates a temporary plus an owned header; adopt transfers the temporary; scratch reuses a scratch header but allocates an owned header. The actual schedule was checked.

The companion investigation archive holds full commands, manifests, original timing sources and summaries under `evidence/`. Paths in those historical receipts identify the experiment workspace, not required local installation paths. Raw results describe the stated shared Linux host and FFmpeg build, not a Mac or the merged non-decoding measurements.
