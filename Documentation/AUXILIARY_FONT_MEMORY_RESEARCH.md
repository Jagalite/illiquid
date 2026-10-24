# Avoiding unused embedded-font copies in auxiliary readers

Research date: 2026-10-24. Baseline:
`4abf4b44f13386ccd04f1ce4ad0e756255ca4d14`. Measured production candidate:
`597a53ef2c6e799486abf7e6b59aa13f86bad87e`.

## Independent native replication

A separate Boolean-option implementation at `979bdd34` completed a macOS
experiment with 228 fresh processes. It confirms reduced live heap ownership,
but retained resident memory and physical footprint rise by approximately 4 MiB
with 16 MiB of fonts and 16 MiB with 64 MiB. Its Debug and Release runs each
passed 73 test functions and skipped ten; all 20 cases in its new auxiliary
suite executed. Those results are source-pinned replication evidence, **not
qualification of this PR's different policy-enum implementation or newer app
source tree**. This PR's own native checks remain necessary.

See [all native results and tradeoffs](AUXILIARY_FONT_MACOS_REPLICATION.md)
and the complete retained receipts. The physical-memory increase needs
investigation before describing this as an overall macOS RAM improvement.

## Result

Secondary media readers do not need their own Swift copies of embedded font
payloads. Opting those readers out removes exactly one payload-length copy per
auxiliary input while retaining the primary input's fonts. The completed Linux
component experiment measured approximately **2 MiB less live allocation for a
2 MiB font with one auxiliary reader**, and **4 MiB less with two**. At the
existing 64 MiB attachment budget, the two-auxiliary stress case saved about
**128 MiB** of live allocator-accounted memory.

All 60 font-bearing auxiliary comparisons improved live allocated bytes. All 48
control comparisons—no supported fonts or no auxiliary reader—were identical
for that metric. Complete projected metadata, primary font hashes, original
codec extradata and packet traces matched in every group.

This is a successful component memory experiment. The macOS application build,
native demuxer/executor tests, libass rendering regression and native allocator
benchmark are **pending CI execution**. The PR should remain draft until those
checks execute successfully. No whole-player peak-RAM or speed improvement is
claimed: measured peak RSS barely changed, and opening times were noisy with
both improvements and regressions.

## Where the extra ownership came from

`FFmpegDemuxer.makeMediaInfo` enumerates each stream and, for admitted font
attachments, constructs a `FontAttachment` containing `Data(bytes:count:)` from
FFmpeg's codec extradata. Every independently opened input previously performed
that copy. Each copied payload survives with that input's `FFmpegMediaInfo`.

The primary `MediaSession` input supplies `mediaInfo.attachments` to both the
main and picture-in-picture subtitle pipelines. The independently opened
audio, subtitle, frame-step, thumbnail and VobSub readers use stream metadata,
codec parameters or packets; their copied font payload arrays have no consumer.
The call-site review also found diagnostic font-name reporting on the primary
media information.

The production change introduces `FFmpegAttachmentPolicy` with a default of
`.supportedFonts`. Selected auxiliary call sites request `.none`. The policy
only gates construction of Swift `FontAttachment` payloads, after the complete
stream record has been appended.

| Input | Policy | Reason |
| --- | --- | --- |
| Primary playback input | Default `.supportedFonts` | Supplies fonts to both subtitle presentation pipelines and diagnostics. |
| Delayed-audio input | `.none` | Reads audio packets and codec parameters. |
| Embedded-subtitle input | `.none` | Uses primary fonts; still receives its original subtitle codec header. |
| External bitmap-subtitle input | `.none` | Reads bitmap packets and codec parameters. |
| Frame-step reader | `.none` | Reads video packets and codec parameters. |
| Thumbnail metadata and timeline readers | `.none` | Read stream metadata or video packets. |
| External VobSub probe | `.none` | Inspects subtitle streams and parameters. |

The production diff is 43 added and 12 removed lines across seven files. Native
FFmpeg attachment extradata remains allocated in each context, every attachment
stream remains represented, and the 16 MiB per-font / 64 MiB total admission
limits remain unchanged. Copying a value-semantic `FFmpegMediaInfo` is not
counted as another payload allocation; this experiment concerns independent
native input opens and their explicit `Data` construction.

## Measured results

Platform: Linux x86-64 with glibc 2.39, Swift 6.3.2, and real FFmpeg 8.1.2 shared
libraries built from the repository's verified corresponding source. Both
variants compile with `-O -swift-version 6 -warnings-as-errors`.

The table reports median **incremental live allocated bytes**, measured while
one primary reader and the stated auxiliary readers are simultaneously alive.
It includes the native contexts and Swift media-info projection, after
subtracting the pre-open allocation sample. Six paired comparisons contribute
to each row. Every live-allocation observation in a given row is deterministic
in this run; the complete raw samples are retained.

| Supported fonts in the file | Auxiliary readers | Baseline bytes | Candidate bytes | Paired bytes saved | Reduction |
| --- | ---: | ---: | ---: | ---: | ---: |
| 128 KiB | 1 | 1,434,512 | 1,303,424 | 131,088 | 9.14% |
| 128 KiB | 2 | 2,145,440 | 1,882,544 | 262,896 | 12.25% |
| 2 MiB | 1 | 17,167,248 | 15,070,080 | 2,097,168 | 12.22% |
| 2 MiB | 2 | 25,742,496 | 21,547,408 | 4,195,088 | 16.30% |
| 16 MiB | 1 | 134,607,760 | 117,830,528 | 16,777,232 | 12.46% |
| 16 MiB | 2 | 201,903,264 | 168,348,048 | 33,555,216 | 16.62% |
| 64 MiB: four 16 MiB fonts | 1 | 537,295,184 | 470,184,640 | 67,110,544 | 12.49% |
| 64 MiB: four 16 MiB fonts | 2 | 805,927,968 | 671,707,296 | 134,220,672 | 16.65% |
| 2 MiB font + 2 MiB unsupported attachment | 1 | 29,549,344 | 27,451,472 | 2,097,872 | 7.10% |
| 2 MiB font + 2 MiB unsupported attachment | 2 | 44,311,744 | 40,116,688 | 4,195,056 | 9.47% |

Source: [all 18 group summaries](../Benchmarks/AuxiliaryAttachmentPolicy/evidence/linux/summary.json),
[108 paired comparisons](../Benchmarks/AuxiliaryAttachmentPolicy/evidence/linux/pairs.json),
and [216 scalar observations](../Benchmarks/AuxiliaryAttachmentPolicy/evidence/linux/observations.jsonl).
The saved `Data` lengths are exactly the font-byte total multiplied by the
auxiliary count. The allocator savings differ by small amounts because they
also include allocation sizing and object/container storage.

The no-font case has identical live deltas of 195,104, 378,416 and 561,440 bytes
for zero, one and two auxiliary readers respectively. All six primary-only
cases also have identical live deltas between variants. There are eight unique
control groups because the no-font/primary-only group belongs to both sets.

These are controlled synthetic workloads, not a distribution of users' files.
The 64 MiB case deliberately exercises the admission limit. Actual savings
depend on admitted embedded-font bytes and how many opted-out readers overlap
in time; the change provides no payload-memory benefit for files without
supported fonts.

### Secondary metrics and tradeoffs

Peak RSS does not demonstrate the same reduction. The small cases have the
same 81,420,288-byte process high-water mark already present before opening.
For the 16/64 MiB cases, paired median peak-RSS differences are less than
168 KiB in either direction despite the large live-allocation differences.
Transient native work and the process high-water floor can obscure the
retained-memory change. This experiment does not establish lower peak physical
memory, macOS physical footprint, or whole-player memory use.

Opening wall/CPU times are descriptive measurements, not a successful speed
benchmark. For example, the 2 MiB / two-auxiliary wall-time medians are
59.45 ms before and 71.16 ms after, while the 64 MiB / one-auxiliary medians
are 2.194 s before and 1.121 s after. Even controls vary. Balanced ordering
helps control drift but does not eliminate scheduler, allocator and filesystem
effects in a shared environment; no latency threshold or speedup is asserted.

After all measured readers are released, allocator residual differences are
small: the candidate retains 16 or 160 extra bytes in three groups and 496 or
1,232 fewer bytes in two groups; the other groups tie. These residuals are
reported rather than treated as zero. There is no claim about long-running
cache behavior or leak elimination.

## Experiment design and scope

The final cohort contains six fixtures × three auxiliary counts × six pairs ×
two variants: **216 fresh subprocesses, 108 paired comparisons, 18 groups**.
Each group has three baseline-first and three candidate-first pairs. No sample
is discarded. Two earlier smoke cohorts are retained separately and are not
pooled into the reported results.

Each process opens and probes actual Matroska inputs through FFmpeg. The
baseline and candidate libraries contain the exact extracted production
`makeMediaInfo` implementation and all its remaining static helpers. The
candidate includes the exact new policy enum. Unchanged supporting types and
eight production C helpers are extracted without substituting native structs
or reimplementing attachment-copy behavior. The manifest records every original
and staged source hash, compiler invocation, driver hash, executable/library
hash, FFmpeg header/library hash and adaptation.

For Linux, the wrapper removes the projection method's private access, omits
the unavailable CoreGraphics import, and excludes unused CoreMedia time
conversion methods. Linux Foundation provides `CGSize`. It compiles the full
stream/media-info declarations and font attachment store, plus the unchanged
presentation error type. **It does not compile the complete macOS demuxer,
serialized input executor, decoders, renderer or application.**

The measured cohort remains alive through the live sample using
`withExtendedLifetime`. Its function returns scalar observations only, so the
readers are destroyed before the after-release sample. Linux live allocation
is `mallinfo2.uordblks + mallinfo2.hblkhd`, including both allocated arena
storage and allocator-owned mmap regions. Peak RSS comes from `getrusage`
before validation. Hashing, JSON serialization and packet validation take place
after the measured cohort closes, using a separate set of readers.

The six performance fixtures contain one-second MPEG-4 video, FLAC audio, ASS
subtitles, a chapter and deterministic font-labelled payloads. These payloads
exercise copy and ownership behavior; they are not valid font-rendering
workloads. Separate native regression fixtures contain small exact byte arrays
and the repository's licensed Noto Sans font. Fixture file and attachment hashes
are recorded. The system FFmpeg used to generate the files is distinct from
the pinned FFmpeg 8.1.2 libraries used to read and measure them.

Validation compares every projected media/stream field, chapters and selected
streams, supported primary payload hashes against the fixture manifest,
original codec-parameter and extradata hashes, and complete packet records
through EOF. Auxiliary payload lengths are checked independently: the baseline
retains every supported font copy; the candidate retains none. All 18 group
validation receipts match. Packet equivalence is recorded as full-trace hashes
and per-stream counts; individual packet payloads are not committed. The
independent evidence audit reconstructs the pairs and summary arithmetic and
verifies source/build provenance: 3,460 checks passed with zero discrepancies.

## Native regression coverage and qualification

`AuxiliaryAttachmentPolicyTests.swift` adds five runtime cases:

1. Default demuxer and executor readers retain exact font bytes after input
   destruction (two parameterized cases).
2. Opted-out readers preserve all metadata, ASS codec headers, complete packet
   payload/timing/flag records, and seek/restart behavior through both APIs
   (two parameterized cases).
3. A real Noto Sans attachment supplied by the primary input produces identical
   nonempty libass subtitle bitmaps, colors, geometry and strides when the
   secondary subtitle input omits its own payload copies.

These tests were added and syntax-checked; their native execution is pending.
The new workflow also runs existing font-admission, native foundation/track,
audio-delay, frame-step, thumbnail and external VobSub suites using the
repository's native Swift Testing runner. It requires real test execution and
JUnit receipts. A separate native benchmark compiles the complete production
demuxer and executor and measures both APIs with macOS allocator statistics.

[Native workflow for the production commit](https://github.com/Jagalite/illiquid/actions/runs/40101500256)
was queued when this report was prepared, with no runner assigned. Queueing is
not a build or test result. Kyoto is unavailable in this Linux workspace;
isolated local component builds ran directly. Future native builds should
follow `AGENTS.md` and the shared Kyoto queue where available. No live macOS UI
interaction or presentation qualification has been performed.

The existing attachment-admission benchmark was updated to accept an immutable
caller-selected baseline and to compile each variant's matching executor. Its
workflow uses the PR base for regression comparisons; unrelated source drift
still fails the shared-dependency guard. This accommodates the new constructor
without weakening payload/metadata equivalence checks.

## Reproduction and retained evidence

See [the benchmark README](../Benchmarks/AuxiliaryAttachmentPolicy/README.md)
for fixture generation, the pinned minimal FFmpeg build, and native/Linux
commands. Run output directories must be new so prior evidence is preserved.

The [evidence directory](../Benchmarks/AuxiliaryAttachmentPolicy/evidence/linux)
contains readable observations, pairs, summaries, manifests, complete group
validation and an independent audit. Compressed receipts retain every
subprocess stdout/stderr, command, original/staged source snapshot and build
log; executable/native-library hashes are recorded instead of committing
binaries. Earlier smoke results are archived separately. The evidence index
provides SHA-256 hashes for the packaged records.

Final packaging removed one extra blank line at the end of `HarnessLinux.swift`.
The exact measured driver remains in the compressed receipts; the separate
`finalization.json` records both hashes and verifies that this is the only
driver-byte difference. Production source and executable behavior are
unchanged by that whitespace cleanup.

