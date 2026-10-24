# Auxiliary reader font memory

This experiment measures the Swift font payload copies owned by secondary media
readers. The primary input continues to supply all supported fonts to the main
and picture-in-picture subtitle pipelines. Independently opened audio, subtitle,
frame-step, thumbnail and VobSub readers do not consume those copies.

The production policy preserves every stream record and FFmpeg's original codec
extradata. It changes only whether `makeMediaInfo` constructs `FontAttachment`
values containing a copied `Data` payload.

See [the research report](../../Documentation/AUXILIARY_FONT_MEMORY_RESEARCH.md)
for the measured results and platform qualification. Evidence is under
[`evidence/linux`](evidence/linux).

A [separate source-pinned macOS replication](../../Documentation/AUXILIARY_FONT_MACOS_REPLICATION.md)
confirms lower live allocations but measures higher retained RSS/physical
footprint in the larger fixtures. Its raw evidence is under
[`evidence/macos-replication-979bdd`](evidence/macos-replication-979bdd).
It does not replace native qualification of this branch's exact implementation.

## Fixtures

`generate-fixtures.py` creates one-second Matroska files with MPEG-4 video, FLAC
audio, ASS subtitles and a chapter. The six performance cases contain no fonts,
128 KiB, 2 MiB, 16 MiB, four 16 MiB fonts, and a mixed 2 MiB font plus a 2 MiB
unsupported attachment. All supported payloads fit the existing 16 MiB per-font
and 64 MiB total limits.

The performance payloads are deterministic synthetic bytes labelled as fonts.
They exercise copying, ownership and bounds; they are not font-rendering tests.
Two additional native regression fixtures contain exact small payloads and the
repository's licensed Noto Sans font respectively. Their manifests include
complete file and attachment SHA-256 hashes.

```sh
python3 Benchmarks/AuxiliaryAttachmentPolicy/generate-fixtures.py \
  --output /tmp/illiquid-auxiliary-fixtures
```

Use a new or empty output directory. Generation never overwrites prior evidence.

## Native macOS experiment

Use the repository's pinned native SDK and follow `AGENTS.md` build coordination.
When Kyoto is available, submit the intended benchmark/test command to its shared
queue. GitHub-hosted runners do not have that local queue and run directly in
isolated workspaces.

```sh
python3 Benchmarks/AuxiliaryAttachmentPolicy/run.py \
  --fixtures /tmp/illiquid-auxiliary-fixtures \
  --output /tmp/illiquid-auxiliary-native-results \
  --pairs 6
```

`--ffmpeg-prefix` defaults to `/opt/homebrew/opt/ffmpeg`; `--swiftc` can select a
compiler. The runner compiles the complete production demuxer and input executor
from the pinned pre-change baseline and the candidate into separate libraries.
The same driver opens one primary reader plus zero, one or two auxiliary readers
through both APIs. It runs 432 fresh-process observations at six pairs per case.

The only extracted dependencies are the unchanged presentation error and bitmap
packet predicates. Neither the native demuxer nor executor is replaced. Source,
header, library, driver and executable hashes are recorded. Unrelated shared
dependency drift fails preparation instead of silently mixing versions.

The native workflow also builds the application graph and runs:

```sh
export ILLIQUID_AUXILIARY_ATTACHMENT_FIXTURE=/tmp/illiquid-auxiliary-fixtures/auxiliary-attachments.mkv
export ILLIQUID_AUXILIARY_REAL_FONT_FIXTURE=/tmp/illiquid-auxiliary-fixtures/auxiliary-real-font.mkv
bash Scripts/tests/run-native-swift-tests.sh --build --jobs 2 \
  --filter 'AuxiliaryAttachmentPolicyTests|FontAttachmentAdmissionTests|NativePlaybackFoundationTests|NativeTrackSelectionTests|AudioDelayTests|FrameStepPerformanceTests|ThumbnailOptimizationQualificationTests|ExternalVobSubTests'
```

The five new runtime cases cover default payload ownership after close; omitted
payloads with identical metadata, ASS headers, complete packets and seeking
through both APIs; and exact headless libass bitmap equivalence using a real font.
These tests require successful native execution before claiming native playback
qualification. Merely queueing the workflow is not a passing result.

## Linux component experiment

This runner uses real FFmpeg contexts and the exact extracted production
`makeMediaInfo` implementation and its helpers. It omits unused CoreMedia methods
and the CoreGraphics import; Linux Foundation supplies `CGSize`. It does not
compile the complete macOS demuxer, serialized executor or player graph.

The measured run uses Swift 6.3.2 with `-O -swift-version 6 -warnings-as-errors`,
and FFmpeg 8.1.2 built from the repository's verified corresponding source. An
existing compatible shared FFmpeg prefix can be passed explicitly. To reproduce
the minimal build, verify `DependencySources` first, extract
`DependencySources/archives/ffmpeg-8.1.2.tar.xz` into a scratch directory, and run
the following from its `ffmpeg-8.1.2` source directory:

```sh
./configure --prefix=/tmp/illiquid-auxiliary-ffmpeg \
  --cc=gcc --disable-everything --disable-programs --disable-doc \
  --disable-network --disable-x86asm --disable-autodetect \
  --disable-avdevice --disable-avfilter --disable-swresample --disable-swscale \
  --enable-shared --disable-static --enable-pthreads \
  --enable-avformat --enable-avcodec --enable-avutil \
  --enable-protocol=file --enable-demuxer=matroska \
  --enable-decoder=mpeg4,flac,ass --enable-parser=mpeg4video,flac
make -j4
make install
```

The archive SHA-256 is
`464beb5e7bf0c311e68b45ae2f04e9cc2af88851abb4082231742a74d97b524c`.
The measured build receipt records the actual compiler, commands, enabled
components, header/library hashes and a runtime SHA-256/decoder-availability
probe. The system FFmpeg executable used to generate fixtures is separate from
the pinned shared libraries used to read and measure them.

From the repository root:

```sh
python3 Benchmarks/AuxiliaryAttachmentPolicy/run-linux.py \
  --fixtures /tmp/illiquid-auxiliary-fixtures \
  --output /tmp/illiquid-auxiliary-linux-results \
  --ffmpeg-prefix /tmp/illiquid-auxiliary-ffmpeg \
  --swift /path/to/swiftc \
  --pairs 6
```

The default baseline is `4abf4b44f13386ccd04f1ce4ad0e756255ca4d14`. Ensure that
commit is present in the checkout. `--cases` and `--auxiliary-counts` permit
explicit smaller experiments; the full cohort is six cases, three auxiliary
counts, six balanced AB/BA pairs and two variants: 216 fresh processes.

## Measurement boundaries

All reader contexts and their projected information remain alive through the
sample, protected by `withExtendedLifetime`. The function then returns scalar
observations only; all readers are destroyed before the release sample. Hashing,
JSON serialization and packet validation run afterward in a separate cohort.

| Metric | Meaning |
| --- | --- |
| Retained font payload bytes | Sum of owned Swift attachment payload lengths across the simultaneous readers. |
| Live allocator delta | Allocator bytes while readers remain open minus the same process before opening. Linux includes both arena and allocator-owned mmap allocations; macOS uses `malloc_zone_statistics`. |
| After-release allocator delta | Residual allocations after the measured reader cohort closes. Runtime/library caches may remain. |
| Peak RSS | Process high-water mark captured before validation. It includes runtime, probing and transient overhead; it is not the player's physical footprint. |
| Opening wall/CPU time | Time to construct the measured readers. Descriptive secondary metrics; no performance threshold is asserted. |

Validation compares every projected media/stream field, chapters and selections,
primary font hashes, codec parameters and original extradata hashes, and complete
packet traces. Native tests additionally cover seek behavior and font rendering.

All observations, including slower timings and noisy RSS controls, are retained.
The experiment does not claim lower whole-player RAM, GPU memory, frame-drop
rate or energy use. The portable mechanism is removal of one unnecessary Swift
font-payload copy per opted-out auxiliary reader; measured allocator/RSS results
apply to the recorded platform and workload.

