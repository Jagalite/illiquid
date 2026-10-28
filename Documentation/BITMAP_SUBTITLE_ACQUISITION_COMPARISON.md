# Bitmap subtitle acquisition: comparison of two borrowing strategies

Status: the common three-variant cohort is pending. This evidence-only change supplies
one comparison protocol; it does not choose or merge a production implementation.
Results below must come from that cohort rather than earlier independently run benchmarks.

## Problem and fixed implementations

During bitmap subtitle seek reconstruction, `activeSubtitlePackets` checks whether a
packet starts an acquisition display set. The original call reads `FFmpegPacket.data`,
which constructs `Data(bytes:count:)` for the entire compressed packet, although the PGS
and DVB classifiers inspect headers and skip object payloads by segment length.
The scan already has cumulative limits of 4,096 packets and 32 MiB across its lookback
attempts; removing a transient payload copy is separate from changing those bounds.
See the fixed [original demuxer][original-demuxer] and [packet owner][packet-owner].

| Variant | Fixed source revision | Acquisition path |
| --- | --- | --- |
| `original` | `ea2ff568237e2667f7b1aeee67b11a44ebe95b72` | `packet.data` followed by the existing `Data` classifiers. |
| `raw_buffer`, [PR #128][pr128] | `aa71f1df6045ef35301fb0a95518b571f02f23b7` | Borrow packet bytes directly into `UnsafeBufferPointer<UInt8>` classifiers. |
| `data_nocopy`, [PR #137][pr137] | `6275059f54fc9ec52873fb7d223ad6f598fd0c47` | Borrow through `Data(bytesNoCopy:count:deallocator: .none)` and retain the existing classifiers. |

Both proposals replace the same copying call in the same seek path; their savings are not additive.
An independent prototype converged on PR #128's raw-buffer design; discovering the two proposals
motivated this comparison rather than a third production fix.

## API and ownership tradeoffs

PR #128 keeps the `Data` entry points and makes each forward to one buffer parser.
Its [packet overloads][raw-packet] validate the native pointer and positive size, then
hold `FFmpegPacket` alive around the synchronous scan. This exposes internal buffer
and packet overloads, with explicit borrowed storage and no `Data` construction on
the packet path. Its [parser extraction][raw-parser] must preserve the old behavior.

PR #137 adds a [demuxer helper][nocopy-demuxer] and leaves the `Data` parsers untouched.
Its narrow helper creates a nonowning `Data` value inside the same owner-lifetime fence.
This reduces parser/API changes, while retaining Foundation's wrapper and representation
work. The common cohort measures the cost of those choices; source inspection alone
does not establish their relative speed or allocation counts on either platform.

Apple documents the [no-copy initializer][data-init] and specifies that
[`Data.Deallocator.none`][data-none] performs no deallocation. It does not make the
`Data` value retain `FFmpegPacket`. Both implementations therefore depend on
[`withExtendedLifetime`][swift-lifetime] to keep the actual owner alive until the
scan finishes. FFmpeg ties [packet payload lifetime][ffmpeg-packet] to its backing
buffer references; the production wrapper eventually releases them with
`av_packet_free`. Borrowed bytes or a nonowning `Data` must not escape that scope.
Neither lifetime fence makes concurrent packet mutation safe.

## Common experiment

The [comparison runner][runner] must compile all three fixed implementations with
the same driver, dependencies, compiler settings, fixtures, and host. It uses actual
Swift/Foundation and FFmpeg packets, rather than a translated parser or mock owner.
The [workflow][workflow] pins Ubuntu 24.04 and the official Swift 6.3.2 Noble container:
`sha256:c4336909a71b2e69b884f4078cdf98c0cd081911632cb349ef72abc4cbed69fc`.
Swift 6.3.2 also accepts PR #128's unchanged `weak let` lifetime test.

The common correctness corpus contains 605 cases, including 221 authored expected
outcomes. Baseline parity complements those expectations; agreement alone would not
exclude a shared bug. Each of the eight timed workloads rotates the same 16 packets
in each variant. Tiny inputs mix positive and negative decisions; larger inputs mix
acquisition before objects, acquisition after objects, object-only packets, and normal
composition packets, including DVB page mismatches. Large objects span legal segment
lengths. These are synthetic classifier inputs, not complete decoded subtitle samples.

For each workload, six triplets use every ordering of three fresh processes once:
`O/R/N`, `O/N/R`, `R/O/N`, `R/N/O`, `N/O/R`, `N/R/O`, where `O` is original,
`R` is raw-buffer, and `N` is Data-noCopy. This balances each variant's position and
provides 144 timed observations overall. Packet construction, fixture checks, and
warmup occur outside the timed interval. Calibration targets 240 ms and every retained
observation must reach the 60 ms minimum for both process CPU and wall time.
Checksums consume the decisions; normalized time accounts for calibrated iteration
counts. Retain all measured observations, including tiny-input outliers, and report
CPU and wall measurements separately. Compare variants within their common triplets.

## Results: pending common-cohort receipts

The table will report median CPU ns per packet. Recompute ratios and ranges from the raw
observations; a lower raw-buffer/Data-noCopy ratio favors raw-buffer. Earlier runs are excluded.

| Workload | Original | Raw-buffer | Data-noCopy | Median paired raw-buffer / Data-noCopy |
| --- | ---: | ---: | ---: | ---: |
| `pgs_tiny` | pending | pending | pending | pending |
| `dvb_tiny` | pending | pending | pending | pending |
| `pgs_mixed_4k` | pending | pending | pending | pending |
| `dvb_mixed_4k` | pending | pending | pending | pending |
| `pgs_mixed_64k` | pending | pending | pending | pending |
| `dvb_mixed_64k` | pending | pending | pending | pending |
| `pgs_mixed_256k` | pending | pending | pending | pending |
| `dvb_mixed_256k` | pending | pending | pending | pending |

Run URL, source/build hashes, FFmpeg version, parity receipt, minimum duration,
CPU/wall ratio ranges, and complete raw measurements: **pending**.
The unchanged [PR #128 tests][raw-tests] (7 tests) and [PR #137 tests][nocopy-tests]
(8 tests) execute separately against their corresponding extracted implementation;
their common-cohort build and execution receipts are **pending**.

## Source, behavior, and lifetime validation

Receipts must identify the fixed Git objects and hashes of complete shared sources,
extracted classifier/helper declarations, C helpers, driver, and each original test file.
The portable build retains the complete production `FFmpegPacket` and required shared
Swift code, exact `FFmpegRational`/`MediaTime.seconds` declarations, and real FFmpeg
headers/libraries. Disclose each omitted Apple import/declaration and driver portability
change. Compiling extracted acquisition code does not compile the full demuxer or app.

Required behavior includes PGS states `0x40`, `0x80`, and `0xC0`; DVB states 1 and 2
with composition-page filtering; rejection of incomplete headers and null/nonpositive
payloads; length-based skipping of object bytes; and correct visible bounds for slices.
A valid acquisition before a malformed tail must still return true immediately.
The two test suites also check unchanged packet bytes/pointers and release of the
packet owner after scanning; PR #128 additionally checks native buffer reference counts
and metadata. Their coverage supports the scoped borrow without proving all future
concurrent uses safe or replacing native seek-restoration tests.

## Historical guard and interpretation limits

The existing [auxiliary-font benchmark][font-benchmark], also reflected in the
[attachment-admission benchmark][attachment-benchmark], requires byte equality of
shared extracted error and subtitle declarations between its historical revisions.
PR #128 changes those parser bytes, so that guard can reject the historical comparison
before timing. This is a source-isolation check, not evidence of a semantic regression
or an intrinsic advantage for PR #137. This evidence-only change does not weaken that
guard, alter its workflow, or reinterpret earlier measurements.

Linux component results can compare these implementations under one runtime; they
cannot establish Apple Foundation performance, end-to-end seek latency, decoded pixels,
whole-player memory use, or native integration. Timing is not an allocation measurement.
Production selection should consider measured differences, API maintenance, and native macOS
regression results. A production preference awaits the common receipts; any native
qualification gap must remain explicit afterward.

[pr128]: https://github.com/Jagalite/illiquid/pull/128
[pr137]: https://github.com/Jagalite/illiquid/pull/137
[original-demuxer]: https://github.com/Jagalite/illiquid/blob/ea2ff568237e2667f7b1aeee67b11a44ebe95b72/Sources/IlliquidNativePlayback/Media/FFmpegDemuxer.swift
[packet-owner]: https://github.com/Jagalite/illiquid/blob/ea2ff568237e2667f7b1aeee67b11a44ebe95b72/Sources/IlliquidNativePlayback/Media/FFmpegPacket.swift
[raw-packet]: https://github.com/Jagalite/illiquid/blob/aa71f1df6045ef35301fb0a95518b571f02f23b7/Sources/IlliquidNativePlayback/Subtitles/SubtitleAcquisitionPacket.swift
[raw-parser]: https://github.com/Jagalite/illiquid/blob/aa71f1df6045ef35301fb0a95518b571f02f23b7/Sources/IlliquidNativePlayback/Subtitles/BitmapSubtitleTimeline.swift
[nocopy-demuxer]: https://github.com/Jagalite/illiquid/blob/6275059f54fc9ec52873fb7d223ad6f598fd0c47/Sources/IlliquidNativePlayback/Media/FFmpegDemuxer.swift
[raw-tests]: https://github.com/Jagalite/illiquid/blob/aa71f1df6045ef35301fb0a95518b571f02f23b7/Tests/IlliquidNativePlaybackTests/SubtitleAcquisitionPacketBorrowTests.swift
[nocopy-tests]: https://github.com/Jagalite/illiquid/blob/6275059f54fc9ec52873fb7d223ad6f598fd0c47/Tests/IlliquidNativePlaybackTests/BitmapSubtitleAcquisitionBorrowTests.swift
[data-init]: https://developer.apple.com/documentation/foundation/data/init(bytesnocopy:count:deallocator:)
[data-none]: https://developer.apple.com/documentation/foundation/data/deallocator/none
[swift-lifetime]: https://developer.apple.com/documentation/swift/withextendedlifetime(_:_:)-4mmpv
[ffmpeg-packet]: https://ffmpeg.org/doxygen/6.1/structAVPacket.html
[font-benchmark]: https://github.com/Jagalite/illiquid/blob/ea2ff568237e2667f7b1aeee67b11a44ebe95b72/Benchmarks/AuxiliaryFontAttachments/run.py
[attachment-benchmark]: https://github.com/Jagalite/illiquid/blob/ea2ff568237e2667f7b1aeee67b11a44ebe95b72/Benchmarks/AttachmentAdmission/run.py
[runner]: ../Benchmarks/BitmapSubtitleAcquisitionComparison/run.py
[workflow]: ../.github/workflows/bitmap-subtitle-acquisition-comparison.yml
