# Bitmap subtitle acquisition packet borrowing

This study measures the PGS/DVB acquisition checks used by
`FFmpegDemuxer.activeSubtitlePackets` during subtitle seek reconstruction. The
original call copied every selected packet into `Data` before reading segment
headers. Object payloads are skipped by length, so copying them is unnecessary.

The candidate wraps the packet bytes in an immutable, non-owning
`Data(bytesNoCopy:count:deallocator: .none)` inside `withExtendedLifetime(packet)`.
Only the parser's Boolean result escapes. The existing PGS/DVB parsers, packet
ownership, page selection, search bounds, and active packet retention remain
unchanged. Foundation may still allocate a small wrapper; this is not a claim of
zero allocations or lower whole-player RSS.

## Reproduce

On macOS with the repository's pinned native SDK:

```sh
python3 Benchmarks/SubtitleAcquisitionBorrow/run.py \
  --pairs 6 --target-ms 120 --output /tmp/subtitle-acquisition-borrow
```

On Linux, build the verified FFmpeg source archive first, then supply the SDK and
Swift 6.1+ compiler explicitly:

```sh
bash Benchmarks/DeinterlacerEOFMemory/build-linux-ffmpeg.sh /tmp/acquisition-ffmpeg
python3 Benchmarks/SubtitleAcquisitionBorrow/run.py \
  --swiftc /path/to/swiftc --ffmpeg-prefix /tmp/acquisition-ffmpeg \
  --pairs 6 --target-ms 120 --output /tmp/subtitle-acquisition-borrow
```

Use the shared Kyoto queue when available, as required by `AGENTS.md`. Otherwise
announce its absence and keep builds serialized. The runner uses isolated build
directories and does not modify the app's `.build` directory. `--tests-only`
performs component compilation, debug/release tests, and complete-output parity
without timing. Every output directory must be new or empty.

## Method and correctness

The baseline is `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`. Both executables compile
the same complete production `FFmpegPacket`, queue, ring buffer, and error
sources. The existing acquisition parser enums are extracted unchanged from
`BitmapSubtitleTimeline.swift`. The candidate additionally compiles the exact
production `isSubtitleAcquisition` method in a minimal `FFmpegDemuxer` namespace;
its body is not rewritten. The call adapters match the old and new demuxer paths.
The runner rejects changes to shared source inputs.

macOS uses the complete CFFmpeg module and `MediaTime.swift`. Linux uses real
FFmpeg 8.1.2 libraries, the exact used C shim helpers, and the unchanged
`FFmpegRational` and `MediaTime.seconds` declarations, avoiding unavailable Apple
frameworks. No packet ownership, parser, or FFmpeg API is mocked. Source and
binary hashes, complete staged sources, command logs, and SDK information are
retained in the result directory.

Eight regression tests cover authored state/page expectations, maximum-length
segments, every truncated prefix, early success before malformed trailing data,
nonzero-index Data slices, missing/nonpositive payloads, packet immutability, and
owner release. The before/after driver also compares individual complete results
over an authored and deterministic malformed-input corpus, including multiple
DVB composition page selections. Every timed result must match its expected
16-packet cycle.

Each timing sample runs in a fresh process after fixture construction and a
256-call warmup. Six pairs alternate baseline/candidate and candidate/baseline
order. Each variant is independently calibrated to the requested minimum CPU
and wall duration, with results normalized per packet. Timings use an ordinary
optimized executable without allocation instrumentation. A separate executable
measures intercepted successful malloc/calloc/realloc request counts and bytes
during the parser loop, using `LD_PRELOAD` on Linux/glibc and dyld interposition on
macOS. A large copying control must register its payload allocation or the run
fails. That counter excludes other allocation APIs and measures allocation
traffic, not live storage or RSS.

The workload sizes model opaque subtitle object payloads, with legal segment
lengths. They are not claimed to be valid decoded bitmap images. Real container
seek/output coverage belongs to the native integration tests in the accompanying
workflow. This experiment does not measure demux I/O, overall seek latency,
decoder performance, display output, energy, or the player's resident memory.

## Results

### Linux component qualification

The portable component passed on Ubuntu 24.04/x86-64 with Swift 6.4 and the
verified FFmpeg 8.1.2 source build. This is supporting portability evidence; it is
not a native-player latency or RSS measurement.

- Eight regression tests executed successfully in both debug and release.
- All 2,124 complete fixture outcomes matched between baseline and candidate.
- Fourteen workloads, six alternating pairs, and 336 retained timing/allocation
  observations completed. Timings and allocation instrumentation used separate
  executables.

| Workload | Median wall time per check | Time reduction | Intercepted requested bytes per check |
| --- | ---: | ---: | ---: |
| PGS · 4 KiB object | 83.5 → 33.3 ns | 60.2% | 4,164 → 65 B |
| DVB · 4 KiB object | 82.5 → 33.9 ns | 58.9% | 4,167 → 65 B |
| PGS · 64 KiB object | 797.2 → 33.5 ns | 95.8% | 65,603 → 65 B |
| DVB · 64 KiB object | 791.2 → 33.5 ns | 95.8% | 65,606 → 65 B |
| PGS · 256 KiB object | 3289.8 → 34.2 ns | 99.0% | 262,217 → 65 B |
| DVB · 256 KiB object | 3314.0 → 34.6 ns | 99.0% | 262,229 → 65 B |

PGS/DVB tiny-packet medians improved by 8.0%/9.0% on this platform. The disabled
and empty controls differed by +0.005 ns and +0.082 ns respectively, with
overlapping observed ranges; these are not evidence of a meaningful change.
Every enabled workload with a nonempty payload still recorded one 65-byte allocation request.
No zero-allocation or whole-player memory claim is made.

The 4 KiB cases contain 4,096 object bytes, the 64 KiB cases contain 65,535,
and the 256 KiB cases comprise four 65,535-byte objects. Each segment header
adds 3 bytes for PGS or 6 for DVB.
The timing result measures only acquisition checks on warmed, synthetic packet
corpora, with result consumption and output-parity checks.

[Run 40635598742](https://github.com/Jagalite/illiquid/actions/runs/40635598742)
tested commit `c5ac134821099654f370a79d3bad0805732383b6`.
[Receipt](evidence/linux-c5ac1348/receipt.json),
[all medians and ranges](evidence/linux-c5ac1348/summary.json), and
[compressed raw receipts](evidence/linux-c5ac1348/raw-receipts.json.gz) are
retained in the repository. The gzip payload is a UTF-8 JSON object mapping
relative output paths to verbatim file contents, including complete paired
observations, calibration, parity, commands, source/binary hashes, and both test
logs. `gzip -dc` reads it without extracting paths.

## References

- [Apple Data no-copy initializer](https://developer.apple.com/documentation/foundation/data/init(bytesnocopy:count:deallocator:))
- [Apple Data.Deallocator](https://developer.apple.com/documentation/foundation/data/deallocator)
- [Swift withExtendedLifetime](https://developer.apple.com/documentation/swift/withextendedlifetime(_:_:)-4mmpv)
- [FFmpeg packet ownership](https://ffmpeg.org/doxygen/trunk/group__lavc__packet.html)
