# Auxiliary input font attachment memory

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
chapters, codec-private data, decoded-input packet fields/payloads/side data,
packet sequences after seeking, and active subtitle packets. The only intended
metadata difference is an empty Swift font inventory for opted-out readers.
Default and explicitly enabled readers must preserve complete font payloads.

The regression suites also verify that owned codec parameters survive input
destruction and that both subtitle pipelines configured by a real
`MediaSession` render the same complete regions as the default-input reference.
That session enables nonzero audio delay and embedded ASS, exercising the
secondary audio and subtitle input constructors while preserving primary font
registration.

The historical `AttachmentAdmission` benchmark is now manual and pinned to its
recorded candidate. Its strict dependency guard intentionally rejects future
executor changes. Its current native regression job remains active on pull
requests; this study supplies the new baseline/candidate comparison.

## Native results

Native qualification results and their evidence references will be recorded
here after the branch workflow completes.
