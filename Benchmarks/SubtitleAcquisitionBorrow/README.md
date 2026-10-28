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

## References

- [Apple Data no-copy initializer](https://developer.apple.com/documentation/foundation/data/init(bytesnocopy:count:deallocator:))
- [Apple Data.Deallocator](https://developer.apple.com/documentation/foundation/data/deallocator)
- [Swift withExtendedLifetime](https://developer.apple.com/documentation/swift/withextendedlifetime(_:_:)-4mmpv)
- [FFmpeg packet ownership](https://ffmpeg.org/doxygen/trunk/group__lavc__packet.html)
