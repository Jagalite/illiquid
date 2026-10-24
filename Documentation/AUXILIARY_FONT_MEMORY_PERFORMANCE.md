# Auxiliary input font attachment memory

This study removes redundant owned font payloads from secondary media readers.
The measured benefit is lower live allocator usage and less input setup/teardown
work for media containing embedded fonts. **It does not demonstrate lower
resident process memory:** the large-font fixtures had approximately 16 MiB
higher current RSS with the candidate, while peak RSS was essentially unchanged.
That adverse result is retained alongside the allocation and timing results.

## Problem and change

The primary playback input supplies embedded fonts to both the main and Picture
in Picture subtitle pipelines. Independent inputs used for subtitle packets,
delayed audio, thumbnails, frame-step timestamps, and thumbnail metadata do not
register fonts. Previously, every one of those inputs nevertheless constructed
its own owning Swift `Data` for every supported font attachment.

`FFmpegDemuxer` and `FFmpegInputExecutor` now accept
`loadFontAttachments: Bool = true`. Verified auxiliary callers pass `false`.
The default primary input still loads the original font inventory, including
when subtitles are initially off or an external ASS file is selected. The
guard runs after stream metadata construction: attachment streams, indices,
timing, chapters, packet reads, seeks, and native codec data remain available.

This change eliminates one additional Swift payload copy per auxiliary input.
The executor's `mediaInfo` and its demuxer's `mediaInfo` share the same `Data`
storage and must not be counted as two copies. FFmpeg still reads and owns
native attachment extradata; that memory remains necessary in each input.

| Input | Font copies after change | Consumer |
| --- | --- | --- |
| Main playback input | Preserved | Main and PiP subtitle font registration |
| Independent subtitle input | Omitted | Subtitle packets, codec data, seek reconstruction |
| Delayed-audio input | Omitted | Audio packets and seeking |
| Timeline thumbnail input | Omitted | Video decoding |
| Frame-step input | Omitted | Video timestamp discovery |
| Thumbnail metadata input | Omitted | Video presence and duration |
| External bitmap/VobSub input | Omitted | Bitmap subtitle stream metadata and packets |

No native pointer is borrowed into Swift font storage. No global cache, shared
demuxer, new resource lifetime, or changed font-admission limit is introduced.

## Experiment

The baseline is main commit
`6f70cd2446fc6ef38d4e5a0fbf96f91b2234e635`. The new benchmark in
[`Benchmarks/AuxiliaryFontAttachments`](../Benchmarks/AuxiliaryFontAttachments)
compiles complete production demuxer and input-executor sources against the
repository's pinned native SDK. Baseline and candidate share all other staged
production dependencies. Compiler, native-library, source, binary, fixture, and
runner hashes identify the measured bytes.

The four controlled Matroska workloads contain two seconds of video, audio,
ASS subtitles, chapters, and respectively zero, 2 MiB, 16 MiB, or 64 MiB of
supported-font-labeled payloads. The largest inventory consists of four
16 MiB attachments, within the existing per-font and aggregate limits. These
synthetic payloads exercise admission and copying; they are not renderable
fonts. A separate integration fixture uses the repository's licensed Noto Sans
font to qualify actual libass rendering.

Each memory observation starts a fresh process, opens one unchanged primary
input, then retains one, two, or three secondary inputs simultaneously. Memory
checkpoints precede payload hashing, packet tracing, and JSON serialization.
The observations retain absolute before/after values and incremental values:

- Allocator bytes in use from `malloc_zone_statistics(NULL)`.
- Resident bytes from `task_info(MACH_TASK_BASIC_INFO)`.
- Process-lifetime peak RSS from `getrusage`.
- Allocation checkpoints after secondary inputs and the primary input are
  released.

Separate processes measure warm-cache input open/probe/close time. The default
font-loading path and no-font media are controls. Balanced AB/BA ordering and
all raw observations are retained; no outliers are removed. Percent changes
use paired observations and may differ from ratios of separate medians.

These are native input-component measurements. They do not establish a
whole-player percentage reduction, a frame-rate improvement, cold-storage
latency, or a benefit for files without embedded fonts. Reader multiplicity and
actual font inventory determine the opportunity in a playback session.

## Correctness qualification

Verification compares all media and stream metadata, selected indices,
chapters, codec-private data, demuxed packet fields/payloads/side data,
packet sequences after seeking, and active subtitle packets. The only intended
metadata difference is an empty Swift font inventory for opted-out readers.
Default and explicitly enabled readers must preserve complete font payloads.

The regression suites also verify that owned codec parameters survive input
destruction and that both subtitle pipelines configured by a real
`MediaSession` render the same complete regions as the default-input reference.
That session enables nonzero audio delay and embedded ASS, exercising the
secondary audio and subtitle input constructors while preserving primary font
registration. This is a session-construction and subtitle-rendering integration
test; it does not run a continuous playback session or measure presentation
latency.

The historical `AttachmentAdmission` benchmark is now manual and pinned to its
recorded candidate. Its strict dependency guard intentionally rejects future
executor changes. Its current native regression job remains active on pull
requests; this study supplies the new baseline/candidate comparison.

## Native results

### Runs and provenance

The first native component experiment completed in
[run 40101084730](https://github.com/Jagalite/illiquid/actions/runs/40101084730),
measuring implementation commit
[`4e64b3d`](https://github.com/Jagalite/illiquid/commit/4e64b3d2b6098536c61710dca2354442c718961c).
Its [complete summary](../Benchmarks/AuxiliaryFontAttachments/evidence/run-40101084730/summary.json),
[provenance and raw-evidence inventory](../Benchmarks/AuxiliaryFontAttachments/evidence/run-40101084730/provenance.json),
and [independent audit](../Benchmarks/AuxiliaryFontAttachments/evidence/run-40101084730/independent-audit.json)
are retained in the repository.
The subsequent application-test build failed on missing inner `try` annotations
in new Swift Testing assertions. Commit
[`a95e1f0`](https://github.com/Jagalite/illiquid/commit/a95e1f09b379a31892181b20f6d9de0a042179c0)
corrects those test expressions without changing production or benchmark code.
The first measurements remain part of the evidence; that failed test build is
not counted as a passing qualification.

The first run used a virtual Apple M1 with three cores and 7 GB RAM, macOS 26.6.2,
Apple Swift 6.3.3, macOS SDK 26.5, and the pinned FFmpeg 8.1.2 native libraries.
Each run uses six balanced pairs for every fixture/policy/reader-count
combination: 192 memory observations, 192 timing observations, and 32 calibration
observations excluded from the final statistics. Eight verification processes
produce 48 full traces across both revisions, both input APIs, and all three
font-loading policies. These are 48 traces compared against the same normalized
reference for each fixture, not 48 independent paired experiments.

### Allocated storage

The following first-run values are medians in MiB (1,048,576 bytes). Allocator
values are the increment between the checkpoint with only the main reader and
the checkpoint with all secondary readers alive. RSS values are absolute process
values at the latter checkpoint. The columns therefore have different scopes.

| Font payload | Secondary readers | Additional allocator MiB, baseline → candidate | Paired allocator MiB saved | Live RSS MiB, baseline → candidate |
| --- | ---: | ---: | ---: | ---: |
| 2 MiB | 1 | 8.235 → 6.235 | 2.000 | 26.781 → 26.664 |
| 2 MiB | 2 | 16.470 → 12.469 | 4.000 | 33.016 → 32.844 |
| 2 MiB | 3 | 24.705 → 18.704 | 6.001 | 39.242 → 39.133 |
| 16 MiB | 1 | 64.251 → 48.235 | 16.016 | 108.766 → 124.703 |
| 16 MiB | 2 | 128.501 → 96.469 | 32.032 | 157.023 → 172.828 |
| 16 MiB | 3 | 192.752 → 144.704 | 48.048 | 205.297 → 221.133 |
| 64 MiB | 1 | 256.400 → 192.383 | 64.016 | 397.453 → 413.289 |
| 64 MiB | 2 | 512.799 → 384.766 | 128.033 | 590.062 → 605.836 |
| 64 MiB | 3 | 769.199 → 577.150 | 192.049 | 782.656 → 798.391 |

All 54 first-run font-bearing auxiliary memory pairs use fewer live allocated
bytes. The savings track one omitted Swift font payload per secondary input plus
small allocation overhead. In the largest case, the paired saving is 201,378,144
bytes: 201,326,592 bytes of font payload and 51,552 bytes of associated allocation
overhead. Incremental live allocator usage falls about 24–25% in these fixtures;
FFmpeg's native attachment data is still present.

All 36 first-run large-font auxiliary pairs have **higher current RSS**. The
median paired increases range from 15.70 to 15.92 MiB. Peak RSS differs only
slightly: the 64 MiB/three-reader case has peak medians of 798.609 MiB for the
baseline and 798.391 MiB for the candidate. The 2 MiB fixtures also show that
removing 2–6 MiB of live allocated storage does not translate into a comparable
RSS reduction.

The measurements do not identify the VM or allocator mechanism behind this
divergence. In particular, allocator-accounted bytes are not proof of unique
physical pages, and release checkpoints do not establish sustained memory
pressure behavior. No memory-pressure, physical-footprint, or long-running
playback experiment was performed. The RSS increase is a real qualification on
the result, not an outlier removed from the study.

### Input setup and teardown

The timed operation opens, probes, and closes a batch of secondary input
executors while one unchanged main input stays alive. It includes constructor
and destructor work, uses warm file cache, and excludes font hashing and packet
verification. It is not a player launch or seek-latency measurement.

| Font payload | Secondary readers | Wall ms per batch, baseline → candidate | Median paired wall reduction | Median paired CPU reduction |
| --- | ---: | ---: | ---: | ---: |
| 2 MiB | 1 | 2.363 → 1.341 | 43.48% | 43.04% |
| 2 MiB | 2 | 4.759 → 3.286 | 33.56% | 28.80% |
| 2 MiB | 3 | 7.513 → 4.249 | 39.41% | 37.51% |
| 16 MiB | 1 | 15.334 → 10.793 | 38.39% | 41.88% |
| 16 MiB | 2 | 24.796 → 17.320 | 36.07% | 36.74% |
| 16 MiB | 3 | 45.609 → 24.096 | 48.32% | 46.74% |
| 64 MiB | 1 | 48.184 → 30.320 | 37.67% | 37.62% |
| 64 MiB | 2 | 134.820 → 66.260 | 45.78% | 45.71% |
| 64 MiB | 3 | 217.674 → 107.321 | 48.37% | 46.87% |

The percentage column is the median of within-pair reductions. It is deliberately
not calculated from the two independent time medians in the preceding column.
52 of 54 font-bearing wall-time pairs improve, and all 54 CPU-time pairs improve.
The two slower wall-time pairs are retained: 16 MiB/one reader, pair 4,
13.554 → 14.936 ms (+10.19%); and 16 MiB/two readers, pair 4,
23.562 → 25.602 ms (+8.66%). Six pairs on one virtual host are not a population
estimate for users' machines.

### Controls and adverse results

Default-loading controls exercise unchanged behavior in both variants. No-font
controls use the new opt-out path when there is no font payload to omit. Every
control has zero median allocator savings; one 16 MiB default-loading pair
differs by 352 bytes, while the other pairs in that control are equal.

| First-run control | Median paired wall reduction | Faster pairs |
| --- | ---: | ---: |
| No fonts, one secondary reader | −0.20% | 3/6 |
| No fonts, two secondary readers | +4.09% | 4/6 |
| No fonts, three secondary readers | −3.40% | 3/6 |
| Default loading, no fonts | −12.30% | 3/6 |
| Default loading, 2 MiB fonts | +5.86% | 4/6 |
| Default loading, 16 MiB fonts | +0.51% | 3/6 |
| Default loading, 64 MiB fonts | −5.78% | 1/6 |

Negative reductions mean the candidate was slower. The mixed control timings
prevent a claim of universal speedup or a timing no-regression guarantee. The
large-font RSS increase and the unfavorable timing observations remain visible
in the complete raw evidence.

### Corrected native qualification

The corrected test run and its full evidence will be recorded here before this
study is submitted for review.
