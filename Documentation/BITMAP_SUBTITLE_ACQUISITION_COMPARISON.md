# Bitmap subtitle acquisition: comparison of two borrowing strategies

The common three-variant experiment completed successfully. **Prefer PR #128's
raw-buffer design for this acquisition check, subject to native macOS qualification
and integration review.** It was faster than the original copying path and PR #137's
no-copy `Data` path in every paired CPU and wall observation in this Linux cohort.
PR #137 also improved larger packets, but regressed the tiny controls.

This research-only change supplies the reproducible comparison and its complete
receipts. It does not change application source or merge either production proposal.
All reported measurements come from [run 40641092782][run]; earlier studies are excluded.

## Problem and fixed implementations

During bitmap subtitle seek reconstruction, `activeSubtitlePackets` checks whether a
packet starts an acquisition display set. The original call reads `FFmpegPacket.data`,
which constructs `Data(bytes:count:)` for the entire compressed packet, although the PGS
and DVB classifiers inspect headers and skip object payloads by segment length.
The scan checks cumulative thresholds of 4,096 packets and 32 MiB across its lookback
attempts before each read. The final packet can cross the byte threshold, so 32 MiB
is not a strict allocation cap. The proposals preserve those checks and retained packets.
See the fixed [original demuxer][original-demuxer] and [packet owner][packet-owner].

| Variant | Fixed source revision | Acquisition path |
| --- | --- | --- |
| `copying` (original) | `ea2ff568237e2667f7b1aeee67b11a44ebe95b72` | `packet.data` followed by the existing `Data` classifiers. |
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

The [comparison runner][runner] compiled all three fixed implementations with
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

## Results from the common cohort

[GitHub Actions run 40641092782][run], job `122659172327`, completed successfully at
benchmark commit `fd50b1822cd388ecf587fb72ce6f6c893019cc2d`. The environment was
Swift **6.3.2**, Ubuntu **24.04** / Linux x86_64, an **AMD EPYC 9V74** host, and FFmpeg
**6.1.1-3ubuntu5** (`libavcodec` 60.31.102, `libavutil` 58.29.100). The [workflow][workflow]
pins the container digest; the [build receipt][build-receipt] records compiler flags,
source identities, library hashes, and binary hashes. No other run supplies samples
to these results.

The table reports median process CPU **nanoseconds per acquisition check**.
Lower is better. The final column is the median of ratios paired within each triplet,
not a ratio of the separately computed medians. Timings include common packet-rotation,
adapter, and checksum overhead.

| Workload | Original | Raw-buffer | Data-noCopy | Median paired raw-buffer / Data-noCopy |
| --- | ---: | ---: | ---: | ---: |
| `pgs_tiny` | 28.752 | 12.079 | 162.463 | 0.0741 |
| `dvb_tiny` | 29.067 | 11.937 | 156.014 | 0.0733 |
| `pgs_mixed_4k` | 163.196 | 12.210 | 155.807 | 0.0775 |
| `dvb_mixed_4k` | 166.039 | 12.572 | 157.666 | 0.0797 |
| `pgs_mixed_64k` | 1,498.497 | 12.549 | 156.948 | 0.0801 |
| `dvb_mixed_64k` | 1,485.587 | 13.132 | 144.506 | 0.0914 |
| `pgs_mixed_256k` | 6,006.260 | 13.662 | 145.339 | 0.0939 |
| `dvb_mixed_256k` | 6,012.210 | 17.812 | 146.392 | 0.1217 |

Raw-buffer scanning reduced paired CPU time relative to the original by **58.2–58.6%**
for tiny controls, **92.4–92.5%** around 4 KiB, **99.1–99.2%** around 64 KiB, and
**99.70–99.77%** around 256 KiB. Relative to Data-noCopy, reductions were **87.8–92.7%**.
These percentages use `100 * (1 - median_paired_ratio)` for each workload.

Data-noCopy reduced paired CPU time by **4.7–6.2%** around 4 KiB, **89.6–90.3%**
around 64 KiB, and **97.57–97.58%** around 256 KiB. However, tiny PGS took **5.566×**
the original time (paired range **5.349–5.868×**) and tiny DVB took **5.415×**
(**4.719–5.948×**). All 12 tiny paired comparisons regressed; all 36 larger-payload
comparisons improved. This is a result for this compiler, Foundation runtime, host,
and workload. It does not establish that Apple Foundation will have the same cost,
or identify the cost as a specific allocation mechanism.

Wall measurements gave the same ordering in every pair. Tiny Data-noCopy/original
wall ratios had medians **5.567×** (range **5.348–5.867×**) and **5.416×**
(**4.720–5.948×**). Full CPU and wall medians, ranges, all individual paired ratios,
and all **144** observations are in [summary.json][summary] and
[measurements.jsonl][measurements]. No timed observation was discarded. The shortest
retained CPU interval was **253.574 ms** and wall interval **253.635 ms**, both above
the declared 60 ms floor.

All three implementations agreed across **605** cases, including **221** independently
authored expected outcomes ([parity receipt][parity]). The unchanged [PR #128 tests][raw-tests]
(**7**) and [PR #137 tests][nocopy-tests] (**8**) passed separately in release mode
against their corresponding extracted implementation ([test receipt][tests]).

A separate read-only audit recomputed all 672 numeric summary fields from the raw
observations, verified all six orderings per workload, checked the 144 timed and
49 calibration output hashes/checksums, and reconstructed all 13 compiled-source
hashes. All 33 source records matched their fixed Git objects; both unchanged
test files and their logs matched the recorded hashes. The exact PR #137 helper,
baseline-identical parsers, and compile flags were confirmed, with no adapter or
extraction discrepancy explaining the tiny-input regression.

The [evidence directory][evidence] retains the complete review bundle and readable
receipts. Its exact compressed bundle SHA-256 is
`a613f97cd8ab2d39138dc0885293910cbc4c167861ea62b42a07edbe6d7f7083`.

## Source, behavior, and lifetime validation

Receipts identify the fixed Git objects and hashes of complete shared sources,
extracted classifier/helper declarations, C helpers, driver, and each original test file.
The portable build retains the complete production `FFmpegPacket` and required shared
Swift code, exact `FFmpegRational`/`MediaTime.seconds` declarations, and real FFmpeg
headers/libraries. The [benchmark README][readme] and build receipt disclose the
omitted Apple imports/declarations and driver portability changes. Compiling extracted
acquisition code does not compile the full demuxer or app.

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

The common measurements favor **PR #128's raw-buffer design** for this check. It
removes the explicit full-payload copying getter and, in this cohort, also avoids
the tiny-input regression of PR #137's wrapper approach. PR #137 remains the smaller
parser/API change and substantially improves larger payloads, but its common-cohort
results do not support choosing it on performance grounds. The proposals replace
the same call site and should be treated as alternatives when integrating them.

This recommendation remains conditional on native macOS build, regression, and
seek-restoration qualification, plus review of the historical benchmark compatibility
issue above. Linux results cannot establish Apple Foundation performance, end-to-end
seek latency, decoded pixels, whole-player memory use, or native integration.

Source inspection establishes removal of an explicit transient payload copy; this
experiment does **not** measure allocation counts, peak/live memory, or RSS. It does
not change or measure the retained reconstruction set, decoding, rendering, FPS,
energy, or live UI behavior. Timings from other compilers or earlier separate studies
cannot be pooled with this cohort. No native macOS performance or integration result
is claimed by this research PR.

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
[readme]: ../Benchmarks/BitmapSubtitleAcquisitionComparison/README.md
[run]: https://github.com/Jagalite/illiquid/actions/runs/40641092782
[evidence]: ../Benchmarks/BitmapSubtitleAcquisitionComparison/evidence/linux-40641092782/
[build-receipt]: ../Benchmarks/BitmapSubtitleAcquisitionComparison/evidence/linux-40641092782/build-receipt.json
[summary]: ../Benchmarks/BitmapSubtitleAcquisitionComparison/evidence/linux-40641092782/summary.json
[measurements]: ../Benchmarks/BitmapSubtitleAcquisitionComparison/evidence/linux-40641092782/measurements.jsonl
[parity]: ../Benchmarks/BitmapSubtitleAcquisitionComparison/evidence/linux-40641092782/parity.json
[tests]: ../Benchmarks/BitmapSubtitleAcquisitionComparison/evidence/linux-40641092782/test-results.json
