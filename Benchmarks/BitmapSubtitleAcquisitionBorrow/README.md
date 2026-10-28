# Bitmap subtitle acquisition packet borrowing

This benchmark isolates PGS/DVB acquisition classification during subtitle seek
reconstruction. The baseline creates `packet.data` before inspecting segment
headers. The candidate inspects the same packet-owned bytes synchronously.

## Counterfactual and source identity

The baseline is pinned to commit
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`. `baseline/manifest.json` records
the original full-source and extracted-prefix SHA-256 hashes. The frozen Swift
files contain exact original prefixes, including their imports:

- `BitmapSubtitleTimeline.swift`, ending immediately before
  `NativeBitmapSubtitleRegion`, supplies the complete PGS/DVB classifiers.
- `FFmpegDemuxer.swift`, ending immediately before `FFmpegDemuxer`, supplies the
  existing retry-policy declarations and, in the candidate, the packet overloads.

The runner verifies these unique boundaries and the frozen baseline against Git.
It compiles the prefixes without changing their statements. Unrelated timeline,
renderer, and full-demuxer dependencies are excluded; no replacement framework
types or packet-owner stubs are introduced. Separate native integration tests
must qualify the complete production call site and module.

Both executables use the complete production `FFmpegPacket`, its timing/error
and bounded-queue dependencies, and the real CFFmpeg module and native libraries.
The runner rejects changes in these shared files and verifies the old/new demuxer
call sites. Only a compile-time branch in the driver selects the copying or
borrowing adapter. Receipts retain full-file and slice hashes, extraction byte
boundaries, compiler/platform/hardware details, flags, SDK/library identities,
binary hashes, exact compiled source snapshots, and command receipts.

## Correctness and timing

Before timing, both executables emit the complete Boolean trace for the same
authored, truncated, malformed, randomly generated, and mutated input corpus.
The traces must agree with each other, and authored cases also have independent
expected outcomes. Coverage includes page selection, PGS state bits, DVB states,
large object segments, missing/nonpositive payloads, and acquisition before or
after malformed input.

Eight timed workloads cover tiny PGS/DVB controls and each codec at approximately
4 KiB, 64 KiB, and 256 KiB. Each workload rotates sixteen real FFmpeg packets.
Large-packet rotations mix acquisition at the beginning, acquisition at the end,
and no accepted acquisition; tiny rotations also mix true and false results.
Object payloads have legal segment framing but synthetic contents. These
particular bytes are not claimed to decode to valid subtitle pixels.

Packet allocation, authored-output validation, and warmup occur outside timing.
Each variant calibrates complete cycles of the same packet distribution toward
240 ms. Eight fresh-process pairs alternate baseline/candidate and
candidate/baseline order. The driver uses non-inlined call adapters and emits a
checksum consuming every result. Every CPU and monotonic-wall observation must
last at least 60 ms. Failed or short observations remain in the output; they are
not discarded. The runner preserves iteration counts, calibration trials, raw
durations, checksums, order, ranges, normalized medians, and paired ratios.

## Reproduce

Use macOS with the repository's pinned native SDK and full Git history. Follow
`AGENTS.md`: submit the runner and native tests through Kyoto when that queue is
available; otherwise explain its absence before direct builds. Build operations
sharing a SwiftPM `.build` directory must remain serialized.

```sh
python3 Benchmarks/BitmapSubtitleAcquisitionBorrow/run.py \
  --pairs 8 --target-ms 240 --output /tmp/bitmap-subtitle-acquisition
```

`--tests-only` builds both executables and checks classifier parity without
timing. The output directory must be new or empty. Running on Linux is rejected
instead of silently substituting a different runtime or native-library model.

## Interpretation

Results measure synchronous acquisition-classification CPU and wall time. The
candidate structurally removes the transient `Data` payload copy at that call
site. It does not change the retained reconstruction packet set or search budget.
This harness does not measure heap-allocation counts, peak/resident memory,
complete seek latency, player CPU, decoded subtitle output, or live UI behavior.
The cumulative 32 MiB reconstruction scan limit is not guaranteed bytes saved per
seek. Real subtitle packet sizes and search patterns determine the absolute
benefit.
