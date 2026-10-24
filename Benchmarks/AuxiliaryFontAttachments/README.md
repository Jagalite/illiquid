# Auxiliary input font ownership

## Problem and change

The primary media input supplies embedded fonts to the main and Picture in
Picture subtitle pipelines. Separate inputs also open the same file for
embedded subtitle packets, delayed audio, timeline thumbnails, duration probes,
and frame stepping. Those auxiliary inputs need metadata and codec parameters,
but do not consume their own Swift-owned font attachment arrays.

Previously, each input nevertheless copied supported attachment payloads from
FFmpeg's native extradata into FontAttachment.data. The change adds
includeFontAttachments, defaulting to true, to FFmpegDemuxer and
FFmpegInputExecutor. The auxiliary call sites pass false; the primary input
keeps its existing behavior. The external bitmap subtitle input and VobSub
preparation probe also omit unused font payloads.

All stream metadata remains present. FFmpeg's native attachment data is not
cleared or freed by this policy. Codec-parameter copies, explicit codec-private
data reads, packet reads, and seeking retain their existing behavior. Both
subtitle pipelines continue to receive the primary input's fonts.

For a file with F bytes of accepted font payloads, one primary plus N auxiliary
inputs previously retained (N + 1) * F bytes in their Swift attachment arrays.
The candidate retains F. This is a count of logical payload ownership; it is
not by itself a claim about physical RAM or whole-player memory.

## Native measurement protocol

The baseline is pinned to 6f70cd2446fc6ef38d4e5a0fbf96f91b2234e635.
The implementation and qualification sources were committed as
89d2534fd7d1f8ccd2f023e1a31bce717bd3adac before the native run.

The benchmark compiles complete production demuxer and input-executor sources
against the repository's pinned FFmpeg SDK. It holds one real primary executor
and zero, one, or two auxiliary executors alive. Each observation starts a fresh
process; there are six alternating baseline/candidate pairs for each of six
fixtures and three auxiliary counts, for 216 observations.

Fixtures include no attachments, 128 KiB, 2 MiB, 16 MiB, and 64 MiB of accepted
font-labeled payloads, plus a mixed accepted/unsupported-attachment case. The
64 MiB case consists of four 16 MiB attachments and represents the aggregate
production font limit. These deterministic payloads exercise ownership and
copying; they are not valid fonts or a representative media collection.

The primary-only and attachment-free groups control for changes outside the
intended auxiliary-font path. No observations are discarded.

### Memory

TASK_VM_INFO supplies process resident bytes and physical footprint while the
complete input group is alive. getrusage supplies process-lifetime peak RSS.
The before/after snapshots are taken before payload hashing, parameter-copy
checks, packet reads, and seek verification.

The report keeps absolute process readings and before/after differences
separate. Peak RSS is a process-lifetime high-water mark, not an incremental
allocation count. The benchmark includes native FFmpeg attachment allocations
in both variants; this change only eliminates the unused Swift copies.

### Output checks and timing

Every observation checks the exact expected primary and auxiliary font-byte
counts. It also compares media metadata, primary font names/MIME/order/hashes,
codec-configuration receipts and extradata, packet payloads and recorded
timestamps/flags, and post-seek packet sequences.

These checks do not compare every native AVCodecParameters field or packet
side-data allocation. They validate the explicitly recorded configuration and
packet fields.

One short group-open interval is timed in each process. Those timing samples
are exploratory; they do not establish a stable player-startup speedup. No
playback FPS, rendering CPU, energy, or cold-storage improvement is inferred.

## Regression coverage

AuxiliaryFontAttachmentTests checks:

- Default inputs preserve independently owned font bytes after demuxer closure.
- Omission preserves metadata, codec data, packet sequences, and seek results.
- The executor forwards the policy while preserving asynchronous opening,
  owned codec-parameter copies, and packet behavior.
- Session construction with embedded subtitles and nonzero audio delay keeps
  primary font ownership and registration while opening auxiliary inputs.

The session-construction test uses synthetic font-labeled bytes. It does not
start playback or qualify real embedded-font rendering, helper thumbnail
pixels, frame-step output, or live audio delay. The primary font path is
preserved and covered at the ownership/registration boundary.

## Reproduce

Use an Apple Silicon macOS host, the pinned SDK, and the compiler selected in
.github/workflows/auxiliary-font-attachments.yml.

~~~sh
python3 Benchmarks/AuxiliaryFontAttachments/generate-fixtures.py \
  --output /tmp/auxiliary-font-fixtures
python3 Benchmarks/AuxiliaryFontAttachments/run.py \
  --fixtures /tmp/auxiliary-font-fixtures \
  --output /tmp/auxiliary-font-results --pairs 6
ILLIQUID_AUXILIARY_FONT_FIXTURE=/tmp/auxiliary-font-fixtures/auxiliary-font-attachments.mkv \
  swift test --force-resolved-versions -c release --jobs 2 --no-parallel \
  --filter 'AuxiliaryFontAttachmentTests|FontAttachmentAdmissionTests|NativePlaybackFoundationTests'
~~~

Output directories must be new or empty. Source, compiler, native-library,
header, fixture, and executable hashes accompany the observations. The workflow
uploads full evidence and emits checksum-protected compressed text bundles in
its logs.
