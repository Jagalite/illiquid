# Subtitle seek acquisition: borrow compressed packet bytes

## Scope and hypothesis

During bitmap-subtitle seek reconstruction,
`FFmpegDemuxer.activeSubtitlePackets` checks selected PGS/DVB packets for an
acquisition state that can restart decoder history. The original call obtains
`FFmpegPacket.data`, which constructs `Data(bytes:count:)` and copies the
complete compressed payload. The acquisition scanners inspect segment headers
and skip object bodies by their advertised lengths. The hypothesis is that a
synchronous borrow removes this unnecessary copy while preserving every scan
decision and packet-ownership rule.

The baseline is main at `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`.
This is a separate call site from the already optimized
[PGS composition-metadata intake](PGS_PACKET_BORROW_PERFORMANCE.md). It affects
bitmap-subtitle seek reconstruction, not normal subtitle pixel decoding.

## Change and ownership argument

`SubtitleAcquisitionPacket.swift` adds packet overloads for the PGS and DVB
scanners. A missing data pointer or nonpositive size returns `false`, as in the
original copying path. Otherwise the adapter creates an
`UnsafeBufferPointer<UInt8>` limited to the packet's size, and calls the scanner
inside `withExtendedLifetime(packet)`. Only a Boolean leaves this synchronous
scope. No pointer, packet, or payload storage is retained in the result.

The existing `Data` entry points forward to the same buffer scanners. Their
loops, bounds checks, state tests, page selection and early returns are
unchanged; a direct source comparison confirms identical parser bodies after
indentation normalization. A valid acquisition followed by a malformed tail
still returns `true`. A malformed segment before the acquisition still returns
`false`. Unknown DVB composition page IDs retain their existing any-page
semantics.

FFmpeg documents the packet buffer's reference-counted ownership and the
unreferencing performed by `av_packet_free` in its
[packet API](https://www.ffmpeg.org/doxygen/8.1/group__lavc__packet.html).
The actual packet owner is unchanged: it frees its owned header and references
in `deinit`. Keeping that owner alive for the scan makes the existing immutable
payload available throughout the borrow. The implementation follows the
project's existing `PGSSubtitlePresentation.update(in: FFmpegPacket)` pattern.

The native adapters are separate from `BitmapSubtitleTimeline.swift` so that
the existing Foundation/CoreGraphics timeline component remains independent
of FFmpeg. The timeline, composition, and region declarations are unchanged.
No queue, generation fence, decoder, packet budget, cache, or synchronization
policy is added or changed.

## Qualification design

[The reproducible runner](../Benchmarks/SubtitleAcquisitionBorrow/run.py)
builds baseline and candidate in debug and release. It uses the complete
production packet owner, exact acquisition-parser declarations, exact shared
time/error/C helpers, and the complete candidate adapter with real FFmpeg
libraries. Shared dependencies must match between revisions. The runner
archives full sources, generated sources, hashes, commands and executable
identities. It also checks that both demux call sites match the benchmark's
adapters.

All four builds must produce identical full traces for 2,222 deterministic
cases. Authored expectations cover every PGS state byte and DVB state/page
combination, maximum segment lengths, truncated inputs, misleading headers
inside object bodies, malformed prefixes and tails, and empty/invalid payload
sizes. Random bytes and mutated valid compositions supplement these cases.
Verification checks unchanged packet pointers, payload bytes and native buffer
reference counts, plus immediate release of each Swift packet owner.

The seven focused regression tests also cover nonzero-index `Data` slices,
packet metadata, and Boolean results surviving payload overwrite and owner
release. The native CI suite additionally generates real PGS/DVD/DVB media.
Its existing container test calls `activeSubtitlePackets` at 8, 16, 21, and 8
seconds, decodes the returned packets, and checks spanning captions and clears.
Another selected test exercises paused seeks through the native session.

The timing cohort uses eight workloads, sixteen rotating packets per workload,
six fresh-process AB/BA pairs, independent iteration calibration, and both
monotonic wall time and process CPU time. Tiny controls and approximately 4 KiB,
64 KiB and 256 KiB packets alternate acquisition state and early/late composition
position. The independently specified checksum is 1,304 per sixteen-packet
cycle. Fixture allocation, warmup and output serialization are excluded from
timing. Each observation must exceed 50 ms for both clocks; no observation is
discarded.

Allocation measurements are separate Linux processes using the existing
glibc interposer, with 4,096 scans and three observations per variant/workload.
It is enabled only around the scan loop. Normal timing processes never load
the interposer. Counts cover successful `malloc`, `calloc` and `realloc`
requests and their requested sizes; they are allocation traffic, not resident
or retained memory.

## Measured results

The completed Linux cohort ran on 2026-10-28 with Swift 6.3.2, real FFmpeg
8.1.2 libraries built from the repository's pinned source archive, and an AMD
EPYC 9V74 host (x86_64, glibc 2.39). The candidate was an uncommitted worktree;
the recorded full-source hashes identify its exact contents. This is a shared
host, so the raw paired observations and their ranges are retained rather than
presenting these medians as precise predictions for a user's machine.

All 96 timing observations passed the duration floor; the shortest wall/CPU
observation was 121.2 ms. Every one of the six pairs improved for every
workload on both clocks. All four debug/release traces matched on all 2,222
cases. The seven dedicated regression tests also executed successfully in both
debug and release against the extracted production component and real FFmpeg
(14 test executions, zero failures; XML receipts retained).

| Workload | Payload bytes/check | Baseline CPU ns/check | Borrowed CPU ns/check | CPU reduction | Allocator-requested bytes/check, before → after |
| --- | ---: | ---: | ---: | ---: | ---: |
| `pgs_tiny` | 14 | 27.3 | 13.1 | 52.1% | 0 → 0 |
| `pgs_object_4k` | 4,113 | 181.7 | 14.2 | 92.2% | 4,178 → 0 |
| `pgs_object_64k` | 65,552 | 1,599.5 | 15.1 | 99.1% | 65,617 → 0 |
| `pgs_acquisition_256k` | 262,173 | 7,023.3 | 16.5 | 99.8% | 262,238 → 0 |
| `dvb_tiny` | 8 | 27.5 | 12.2 | 55.7% | 0 → 0 |
| `dvb_object_4k` | 4,110 | 197.8 | 12.9 | 93.5% | 4,175 → 0 |
| `dvb_object_64k` | 65,549 | 1,589.8 | 12.0 | 99.2% | 65,614 → 0 |
| `dvb_acquisition_256k` | 262,182 | 6,964.3 | 20.8 | 99.7% | 262,247 → 0 |

CPU values are medians of six independently normalized fresh-process
observations. The wall-time reductions range from 52.1–55.7% for tiny controls
and 92.2–99.8% for the larger packets. All 48 separate allocation observations
agree: the six larger workloads drop from two allocation requests per check to
zero, and both tiny controls remain at zero. On this Linux Foundation/runtime,
the baseline's cumulative requested bytes are the payload size plus 65 bytes
per check. These are allocator requests, not live memory.

For example, 4,096 checks of the approximately 64 KiB PGS workload requested
268,767,232 bytes cumulatively in the baseline and zero inside the candidate
scan loop. The checks do not retain those baseline allocations simultaneously;
this is approximately 256 MiB of avoided allocation traffic, **not** a 256 MiB
reduction in the player's memory footprint.

The mechanism and measurements support the optimization: the scanner's work
scales with segment headers, while the removed allocation/copy scales with
compressed payload size. The benefit is bounded to acquisition classification
when bitmap subtitle seek reconstruction reaches this call site.

See [the retained evidence index](../Benchmarks/SubtitleAcquisitionBorrow/evidence/linux/README.md)
for reviewed summaries, all numeric observations, source hashes, test results,
and compiler/dependency provenance. Local command logs, absolute paths, source
snapshot archives and executable files are omitted from the public evidence.
The independent audit used the complete original local records. No timing
observation was discarded. A
compiler smoke initially rejected a Swift 6.3 weak-binding warning in the driver;
that diagnostic was corrected before measurement. A later launch failed for
lack of temporary disk space before creating any benchmark output. Those
preflight events did not produce performance observations.

## Native integration and historical benchmark compatibility

[The dedicated workflow](../.github/workflows/subtitle-acquisition-borrow.yml)
uses the reviewed macOS native SDK, repeats the component comparison, builds
the application/test graph, and runs acquisition, bitmap decoding/seek, PGS
metadata/crop, and packet-ownership suites. Its artifacts include source
snapshots, command output, test logs and machine-readable execution receipts.
At the time of this local qualification, the full macOS application and native
seek tests have not yet executed; the PR workflow is their integration gate.

The older auxiliary-font comparison requires byte-identical historical helper
declarations. Its manual reproduction is therefore pinned to the pre-borrowing
main revision. The auxiliary-font PR workflow still builds and runs the current
native attachment/rendering regression suites; it no longer stops those tests
at the historical helper-identity guard. The historical harness and evidence
remain unchanged.

## Interpretation limits

The optimization removes one complete compressed-payload copy per selected
PGS/DVB packet that reaches an acquisition check. The seek lookup's 4,096-packet
and 32 MiB inspected-byte budgets count all demuxed packets, including unrelated
streams. They are not the amount of memory saved per seek, and the final packet
can overshoot the byte budget. Already-retained compressed packets and decoder
history remain owned exactly as before.

The component benchmark does not include file I/O, demuxing, decoding, renderer
work, or scheduling. Its synthetic object bodies are legal-length inputs to the
header scanners, not a decoded-image corpus. Component timing improvements must
not be reported as equivalent whole-player speedups. Allocation-request savings
must not be reported as peak heap, RSS, GPU memory, macOS physical footprint,
or battery savings. Absolute benefit depends on selected subtitle packet sizes
and how often seek reconstruction checks them. Live UI responsiveness and
whole-player memory are outside this qualification.

## Reproduce

Follow the [benchmark README](../Benchmarks/SubtitleAcquisitionBorrow/README.md)
for commands, dependencies, source-extraction boundaries and retained outputs.
Build through Kyoto when it is available. The Linux investigation and hosted
macOS jobs have no shared Kyoto queue and use isolated direct builds.
