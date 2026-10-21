# Audio format metadata preparation

This experiment compares the audio format bookkeeping in `AudioDecoder.convert`
at `a2de305c8dbcaa81aac1477df7c9a0017c14eae3` with the current working tree. It
uses real FFmpeg `AVFrame` objects and the real, pinned `libavutil`. The runner
extracts the preparation block from each decoder verbatim, substituting only a
precomputed output-channel count for the device-capacity lookup. It also stages
the unchanged metadata shim functions and C-string conversion function. The
candidate's complete `AudioSourceFormat.swift` is compiled without modification.

## Run

Swift 6 and Python 3 are required. On the repository's macOS CI runner, install
the reviewed SDK with `Scripts/install-ci-native-sdk.py` first. On Linux, build
`libavutil` from the repository's pinned FFmpeg source archive and pass its prefix.

```sh
python3 Benchmarks/AudioFormatMetadata/run.py \
  --ffmpeg-prefix /opt/homebrew/opt/ffmpeg \
  --output /tmp/audio-format-metadata

python3 Benchmarks/AudioFormatMetadata/run.py \
  --swiftc /path/to/swiftc --ffmpeg-prefix /path/to/ffmpeg-prefix \
  --tests-only --output /tmp/audio-format-metadata-parity

# The production helper's Swift Testing regression suite, in debug and release.
python3 Benchmarks/AudioFormatMetadata/run-tests.py \
  --swift /path/to/swift --ffmpeg-prefix /path/to/ffmpeg-prefix \
  --output /tmp/audio-format-metadata-tests
```

Each output directory must be new or empty. Defaults are six balanced AB/BA
pairs per workload, an 80 ms baseline target, and a 5 ms minimum target for
each variant. Calibration runs two pilots per variant (100,000 preparations
for the fast candidate), uses the faster pilot rate, and adds a 2x margin to
the minimum target. Both members of a pair use the same iteration count, with
a five-million-iteration cap. `calibration.json` retains all pilots and records
whether that cap applied. The measured durations are checked independently;
`summary.json` and `completion.json` explicitly flag any observation below the
requested minimum. This is a measurement-quality flag, not a speedup threshold.
Each observation runs in a fresh
optimized process; frame allocation, warmup, and result encoding are outside
the measured interval. Every preparation result contributes to the checksum.
The complete final metadata and checksum must match within every pair.

The separate parity pass compares every metadata field, the format-change
decision, and cumulative format revision for 1,025 frames per workload plus a
trace that mutates one reused `AVFrame` in place. It includes native and
unspecified layouts, custom named channels, ambisonic layouts, same-count layout
changes, sample-rate and sample-format changes, and output-device channel-count
changes. The custom and ambisonic cases retain the uncached fallback. The
every-frame changes are deliberate adverse controls for cache misses.

`run-tests.py` stages the complete production helper and regression test file in
an isolated Swift package with an `IlliquidNativePlayback` module. It does not alter the
test source or resolve remote packages. The Linux runner selects SwiftPM's
integrated driver for restricted process namespaces. The package still links
real libavutil and is not a substitute for the full native app test graph.

`summary.json` reports medians in nanoseconds per prepared frame, observed
ranges, and paired ratios. The output retains raw timings, complete parity
traces, commands, compiler flags, source snapshots and hashes, binary hashes,
and the linked libavutil identity. There is no noisy timing threshold in CI.

This is a component experiment. It does not decode compressed audio, perform
resampling, measure renderer submission, or measure whole-player CPU, battery
use, or playback latency. Native decoder and resampler regression tests remain
a separate required validation step.
