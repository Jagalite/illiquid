# Auxiliary-input font memory

The playback input supplies embedded font attachments to the subtitle
pipelines. Independent inputs for thumbnail decoding, thumbnail metadata,
frame stepping, delayed audio, and subtitle packets do not consume their own
copies of those font payloads. The candidate explicitly opts those readers
out of copying fonts into `FFmpegMediaInfo.attachments`, while the default
input behavior and attachment stream metadata remain available.

This experiment compares complete production input objects against main at
`6f70cd2446fc6ef38d4e5a0fbf96f91b2234e635`. It measures memory while the
objects remain alive. Native FFmpeg still reads and retains the container's
attachment data; the change avoids an additional Swift-owned payload per
auxiliary input.

## Reproduction

Portable input/provenance checks require Python 3.11+ and a checkout containing the
baseline commit:

```sh
python3 Benchmarks/AuxiliaryFontMemory/run.py --validate-inputs
```

Native measurements require Apple Silicon macOS, Swift 6.1 or later, and the
repository's verified FFmpeg SDK installed at `/opt/homebrew/opt/ffmpeg` (or
passed through `--ffmpeg-prefix`). Both output directories must be new/empty.
No downloads occur in either script.

```sh
python3 Benchmarks/AuxiliaryFontMemory/generate-fixtures.py \
  --ffmpeg /opt/homebrew/opt/ffmpeg/bin/ffmpeg \
  --output /tmp/auxiliary-font-fixtures
python3 Benchmarks/AuxiliaryFontMemory/run.py \
  --fixtures /tmp/auxiliary-font-fixtures \
  --output /tmp/auxiliary-font-results \
  --pairs 4
```

The generator also creates `auxiliary-font-integration.mkv`, used by the
native regression suite via `ILLIQUID_AUXILIARY_FONT_FIXTURE`. It contains
video, audio, ASS subtitles, two chapters, an unsupported binary attachment,
and two supported font-labeled attachments with exact five- and six-byte
payloads. Synthetic font bytes test ownership and admission; they are not
renderable fonts.

## Fixed cohort

| Input | Supported font payload | Other attachment payload |
| --- | ---: | ---: |
| `none` | 0 | 0 |
| `font-128kib` | 128 KiB | 0 |
| `font-2mib` | 2 MiB | 0 |
| `fonts-16mib` | Four × 4 MiB | 0 |
| `unsupported-8mib` | 0 | 8 MiB |
| `mixed` | 128 KiB | 8 MiB |

Every container includes 0.5 seconds of FFV1 video, FLAC audio, ASS subtitles,
and chapter metadata. All attachment payloads are deterministic arbitrary
bytes. Container identifiers may vary when regenerated; each run records
exact container hashes and original payload hashes.

The six profiles are one or three auxiliary demuxers, one or three auxiliary
executors, one default demuxer, and one default executor. Default controls
include fonts in both variants. The baseline auxiliary profiles also use the
original default constructor; candidate auxiliary profiles explicitly pass
`includeFontAttachments: false`.

At four pairs, the matrix has **288 fresh measurement processes**: six
fixtures × six profiles × four pairs × two variants. Each profile alternates
AB/BA order across pairs. There are no adaptive repeats, timing calibration,
sample exclusions, or memory-pressure-induced process reuse.

## Metric and sampling boundary

The primary measurement is Darwin
`malloc_zone_statistics(NULL).size_in_use`, across all allocator zones. The
reported retained delta subtracts a warmed empty reading from a reading
taken after all requested production input objects have been opened. This is
allocator-accounted live memory for the input experiment, including FFmpeg
and runtime allocations. It is **not RSS, peak memory, a per-object allocator
enumeration, or whole-player memory**.

Each process warms the selected input API once using the no-attachment
fixture, then releases that input. The holder array reserves capacity before
the empty reading. Measured constructors run inside an autorelease pool;
that pool drains before the retained reading. Each input receives a
serialized production `codecPrivateData(streamIndex: -1)` call, returning nil,
so an executor's opening closure has finished before sampling. This operation
does not read a packet or allocate an attachment payload.

All measured inputs stay strongly owned through sampling and verification.
The exact sum of retained `FontAttachment.data.count` and the attachment
count are recorded separately. Metadata serialization, SHA-256 hashing,
codec-private-data copies, packet reads, seeks, and JSON output occur **after**
the allocator reading. Their allocations cannot inflate the reported live
delta. No release-memory or process-timing claim is made.

Absolute before/after medians, ranges, and every paired byte/percentage change
are retained. A percentage is computed within each baseline/candidate pair;
its reported median need not equal the ratio of the two displayed memory
medians. The no-font, unsupported-only, and default-input controls expose
runtime or allocator noise.

## Correctness and provenance

Both variants compile these complete, unmodified production files in a
separate optimized Swift module: `FFmpegDemuxer`, `FFmpegInputExecutor`,
`FFmpegStreamInfo`, `MediaTime`, `FFmpegError`, `FFmpegPacket`,
`FontAttachmentStore`, `PacketQueue`, and `FixedRingBuffer`. The CFFmpeg module
map and shim are identical. Only the two files implementing the new input
parameter may differ between variants. There are no mock input APIs, source
body rewrites, or changes to access control.

As in the existing `AttachmentAdmission` benchmark, the required
`PresentationError` and bitmap packet declarations are extracted verbatim
using unique, checked boundaries. The metadata serializer follows that
benchmark's serializer. Both variants use the same harness source; only the
candidate driver enables its explicit auxiliary opt-out call.

For every retained input, the harness records every stored media-info and
stream field, derived stream selections, exact floating-point bit patterns,
all chapter metadata, and font names/MIME/order/payload hashes. It also records
codec-private payload length/SHA-256 for every stream, then the complete
packet sequence to EOF and again after a real seek. Each packet receipt
includes stream, timestamps, duration, generation, time base, flags, file
position, full payload hash, and every side-data payload hash.

The runner requires these receipts to match across every owner, count, role,
pair, and variant after removing only the intentionally omitted Swift font
array. Every default font descriptor/hash must match the generator's original
bytes. Auxiliary native attachment codec-private payloads must also match
those bytes, demonstrating that opt-out has not removed FFmpeg's own data.
All three media streams must produce packets both initially and after seek.

`baseline.json` pins the baseline commit and SHA-256 of every source input.
The result directory retains both source snapshots, extracted support,
harness inputs, compiler/SDK/host information, native library and header
hashes, fixture-generation commands, build logs, command receipts, raw
observations, a canonical parity receipt per fixture, and the complete
summary. Candidate source, harness, and fixture hashes are checked again
after the cohort. Command elapsed times are provenance only and are not used
to claim a speedup.

This component comparison does not construct `MediaSession`, render fonts,
decode video, or exercise the UI. Those behaviors require the separate native
application build and regression qualification.
