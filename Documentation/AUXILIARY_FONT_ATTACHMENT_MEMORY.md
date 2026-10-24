# Auxiliary input font attachment memory research

## Decision: retain the research; withhold a production PR

The candidate removes unused owning Swift font copies and passes its native
correctness checks. It does **not establish an overall memory-performance
improvement** on the tested macOS host. Live malloc allocations fall, but
retained resident memory and physical footprint consistently increase for the
16 MiB and 64 MiB font fixtures. Opening times are inconsistent.

No production PR is proposed from this experiment. The candidate remains on a
research branch with the complete measurements and regression tests. The
physical-memory result needs explanation and further representative
qualification before recommending this implementation for the player.

## Finding and candidate

At baseline `6f70cd2446fc6ef38d4e5a0fbf96f91b2234e635`, every
`FFmpegDemuxer` copies supported embedded-font bytes into owning Swift `Data`
values in `makeMediaInfo`. Separate readers for subtitle packets, delayed
audio, thumbnails, duration probes, frame-step timestamps and VobSub stream
discovery retain copies they do not use to register fonts.

Both the main and Picture in Picture subtitle pipelines receive fonts from
`MediaSession`'s primary `mediaInfo`. The candidate adds a default-enabled
`includeFontAttachments` argument to the demuxer and input executor and opts
seven auxiliary constructor sites out. Stream descriptors are appended before
the payload inclusion check, preserving attachment stream metadata, track
selection, chapters, timing, codec configuration and packet behavior. Primary
and diagnostic defaults still own their font payloads.

FFmpeg's original attachment extradata remains allocated. The optimization only
removes the additional Swift projection. Its expected logical saving is the
accepted font payload size multiplied by the number of auxiliary inputs.

## Native experiment

[Qualification run 40101300598](https://github.com/Jagalite/illiquid/actions/runs/40101300598)
completed successfully on candidate
`979bdd34a93af1c564d505b1b6a4f6b12de27379` on October 24, 2026.

- Host: virtual Apple M1, 7 GiB RAM, macOS 26.6.2.
- Toolchain: Apple Swift 6.3.3, Xcode 26.6, macOS SDK 26.5,
  and the repository's pinned FFmpeg 8.1.2 SDK.
- 19 scenarios, six balanced AB/BA pairs each: **228 fresh processes** and
  **396 retained-reader receipts**. All observations are retained.
- Inputs: identical short H.264 video, FLAC audio, ASS cues and chapters,
  remuxed with no attachments, 2/16/64 MiB font-labeled payloads,
  unsupported-only attachments, or mixed attachments.
- Payloads are synthetic repeating byte patterns, not valid fonts or a
  representative real-font corpus. The 64 MiB case is a stress workload.

The benchmark compiles complete, unmodified production input sources from
both revisions. Its small supporting declarations are extracted verbatim and
verified identical. It holds every designated input alive while sampling
current memory, before font hashing, metadata serialization or packet checks.
It measures the input component without a complete running player, decoders
or rendering pipeline. The native tests separately exercise actual callers.

## Main result: live allocations and physical memory disagree

All values below are MiB (1,048,576 bytes), for **one primary plus two auxiliary
executors**. Absolute values are separate per-variant medians; changes are
medians of paired `candidate - baseline` differences. Positive changes mean
more memory, so a difference between displayed medians need not equal the
paired change.

| Font payload | Baseline heap | Candidate heap | Paired heap change | Baseline footprint | Candidate footprint | Paired footprint change |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| No fonts | 1.335 | 1.335 | -0.000 | 4.501 | 4.556 | +0.070 |
| 2 MiB | 25.489 | 21.489 | -4.000 | 24.931 | 24.915 | -0.000 |
| 16 MiB | 193.328 | 161.295 | -32.033 | 149.869 | 153.838 | +3.969 |
| 64 MiB stress | 769.328 | 641.295 | -128.033 | 582.105 | 598.120 | +15.977 |

The exact Swift payload inventory falls from 6 to 2 MiB, 48 to 16 MiB, and
192 to 64 MiB respectively in the three font-bearing rows. Primary font bytes
and hashes remain unchanged. Malloc statistics include allocation overhead,
so their reductions slightly exceed the logical payload sizes.

Across the direct-auxiliary, primary-plus-one and primary-plus-two layouts,
**all 36 paired comparisons for the 16/64 MiB fixtures have higher retained
RSS and physical footprint**. The physical-footprint increases are about
4 MiB for 16 MiB fonts and 16 MiB for 64 MiB fonts. In the 64 MiB two-auxiliary
case, every paired footprint increase is between 15.937 and 16.062 MiB.
Subtracting each process's pre-open sample leaves the adverse result:
+3.961 MiB and +15.969 MiB for the 16/64 MiB two-auxiliary cases.

No-font and primary-only controls have zero paired median heap change and
much smaller physical-memory drift. The largest primary-only paired footprint
drift is about 0.22 MiB. Two-MiB font cases do not establish a meaningful
physical-memory reduction. Peak RSS measured by the retained checkpoint is
approximately unchanged; it does not establish a peak-memory benefit.

These measurements do not identify the underlying allocator or VM mechanism.
Lower live allocator ownership must not be equated with lower physical RAM.
Allocator caching, page sharing and page accounting are possible subjects for
further investigation, not explanations established by this experiment.

### Opening time

Opening/probing timings are secondary, single-operation observations with
substantial variation. For primary plus two auxiliaries, the 16 MiB fixture is
37.33% slower by median paired wall-time ratio, while the 64 MiB fixture is
24.61% faster. Both paired ranges contain faster and slower candidate results.
The study therefore supports **no general setup-speed claim**.

### After-release samples

Every weak lifetime probe confirms that its input owner was destroyed. The
later memory sample follows variant-dependent hashing of font payloads and
construction of packet/metadata receipts. Baseline processes do more font
hashing because they own more copies. Allocator retention from that validation
work can affect the sample. Lower after-release footprint must **not** be
presented as production post-close savings or as a clean teardown comparison.

## Correctness and independent audit

Native debug and release builds both succeeded. Each selected test run reports
83 test functions across 10 suites: **73 passed and 10 explicitly skipped**.
The new five-function auxiliary-font suite ran all 20 parameterized cases in
both configurations. It checks default font ownership after demuxer destruction;
full non-font metadata, packet bytes/flags/side data, codec configuration,
seek/subtitle reconstruction through both input APIs; duration/frame-step
results; and matching thumbnail pixels.

The 10 skips are explicit: one historical attachment fixture test, two frame-step
performance tests, and seven timestamp-discovery tests. Their separate fixture
sets were not supplied. They are not counted as passing qualifications. The new
suite's own thumbnail, metadata and frame-step checks did execute.

The independent audit verified all 228 observations and their execution order,
396 reader receipts, expected attachment bytes/counts/hashes, exact metadata,
codec-private data, initial/seek packet parity, and owner release. It recomputed
every summary field exactly, matched 31 source hashes and three benchmark hashes
to the pinned revisions, verified the evidence checksum, and checked all 255
recorded commands exited successfully. No samples were discarded or selected
for a favorable result.

## Complete scenario summary

Memory columns below are median paired changes in MiB, `candidate - baseline`.
Opening time is the median paired percentage change; positive is slower.

| Fixture | Input layout | Heap change | RSS change | Footprint change | Open time change |
| --- | --- | ---: | ---: | ---: | ---: |
| none | direct / auxiliary-only | -0.000 | +0.055 | +0.055 | -0.80% |
| fonts-2mib | direct / auxiliary-only | -2.004 | -0.031 | +0.016 | -9.58% |
| fonts-16mib | direct / auxiliary-only | -16.020 | +3.906 | +3.984 | -0.03% |
| fonts-64mib | direct / auxiliary-only | -64.020 | +15.969 | +16.047 | +3.60% |
| unsupported-only | direct / auxiliary-only | -0.004 | +0.086 | +0.164 | -3.43% |
| mixed | direct / auxiliary-only | -2.004 | -0.070 | +0.008 | -7.01% |
| none | executor / primary-plus-one | -0.000 | +0.031 | +0.031 | -3.70% |
| fonts-2mib | executor / primary-plus-one | -2.000 | -0.008 | -0.008 | -6.21% |
| fonts-16mib | executor / primary-plus-one | -16.016 | +4.055 | +4.039 | +5.62% |
| fonts-64mib | executor / primary-plus-one | -64.016 | +16.055 | +16.055 | -2.65% |
| unsupported-only | executor / primary-plus-one | -0.000 | +0.094 | +0.094 | -1.01% |
| mixed | executor / primary-plus-one | -2.000 | +0.094 | +0.094 | -6.18% |
| none | executor / primary-plus-two | -0.000 | +0.070 | +0.070 | +6.63% |
| fonts-2mib | executor / primary-plus-two | -4.000 | -0.000 | -0.000 | -9.17% |
| fonts-16mib | executor / primary-plus-two | -32.033 | +3.992 | +3.969 | +37.33% |
| fonts-64mib | executor / primary-plus-two | -128.033 | +15.992 | +15.977 | -24.61% |
| none | direct / primary-only | -0.000 | -0.000 | -0.000 | -7.91% |
| fonts-2mib | direct / primary-only | -0.000 | -0.023 | -0.023 | +12.79% |
| fonts-16mib | direct / primary-only | -0.000 | +0.133 | +0.133 | -0.40% |

## Evidence and reproduction

The [benchmark README](../Benchmarks/AuxiliaryFontAttachments/README.md) provides
native reproduction commands and the measurement protocol. Evidence is retained
in [native-20261024](../Benchmarks/AuxiliaryFontAttachments/evidence/native-20261024):

- Readable summary, source/toolchain manifest and independent audit.
- A losslessly compressed bundle containing every raw observation, complete
  parity receipts, fixture inventory and command receipts.
- Debug/release test logs and explicit skip summaries.
- Checksums connecting the committed archive to the original verified CI bundle.

The original gzip bundle SHA-256 is
`c41dd484029d280b670b376c1a493e8b9f2f3c131e059cd7d26dda2dc7c2bcdd`.
Its exact uncompressed bytes were repacked as XZ for a smaller permanent archive;
`archive-receipt.json` records both representations and the shared content hash.

Later branch commits only tighten an older benchmark dependency guard and add
research documentation/evidence; the measured production candidate is the
explicit commit above. Main advanced during the study with unrelated subtitle
conversion and UI work. Those changes are outside this pinned qualification.

## Scope and next investigation

The font validator permits at most 16 MiB per font and 64 MiB in aggregate for
successful subtitle-pipeline configuration. Demuxer materialization precedes
that validation; these are not universal bounds on arbitrary file-open memory.

One hosted VM and synthetic repetitive payloads cannot establish results for
every real media library. A useful follow-up would use real-font fixtures and
allocation/VM traces to explain the retained-footprint increase, then test a
representative full session and repeated open/close lifecycle. That investigation
should precede a claim of reduced player RAM or a recommendation to ship.
