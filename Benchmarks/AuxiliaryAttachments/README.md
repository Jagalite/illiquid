# Auxiliary input font memory

Illiquid opens independent FFmpeg inputs for embedded subtitles, delayed audio,
thumbnail decoding, duration probes, and frame-step reads. Previously each input
copied supported embedded fonts into its own `FFmpegMediaInfo.attachments`, even
when that reader never used the copies. Both subtitle renderers receive their
font attachments from the primary playback input.

The candidate adds an explicit attachment payload policy and selects `.omit`
at those auxiliary call sites. The default remains `.copyFonts`. Stream entries,
codec parameters/private data, packet reads, seek behavior, and the primary
input's font recognition, ownership and validation remain unchanged. FFmpeg still
owns its original attachment storage in every input; this change removes the
additional Swift-owned payloads.

## Study design

`run.py` compiles the complete production demuxer, input executor, packet and
queue sources from baseline `4abf4b44f13386ccd04f1ce4ad0e756255ca4d14` and the current
worktree into separate native libraries. The two shared declarations needed by
those files (`PresentationError` and the PGS packet helper) are extracted from
production with source receipts. No production function is rewritten or stubbed.
The same driver is compiled against both libraries; only the candidate's auxiliary
open calls supply the new `.omit` parameter.

Each observation runs in a new process and keeps a primary `FFmpegInputExecutor`
plus the selected auxiliary readers alive. Eight alternating baseline/candidate
pairs are collected for every fixture and reader arrangement. Inputs are opened
sequentially, as in session construction. Main-thread setup autorelease temporaries
are drained before sampling. Fixture generation and verification warm the
filesystem cache; this is not a cold-storage benchmark.

| Arrangement | Primary executor | Auxiliary executors | Direct auxiliary demuxers |
|---|---:|---:|---:|
| Primary-only control | 1 | 0 | 0 |
| Embedded-subtitle reader | 1 | 1 | 0 |
| Subtitle and delayed-audio readers | 1 | 2 | 0 |
| Thumbnail-style reader | 1 | 0 | 1 |

The fixture set contains a no-font control, the repository's real Noto Sans font,
one 8 MiB font-labeled payload, and four 8 MiB font-labeled payloads. The larger
payloads are deterministic arbitrary bytes for ownership/copy stress, not valid
fonts or a representative media corpus. Their sizes remain within the existing
per-font and aggregate attachment limits. Every benchmark fixture contains a
short FLAC audio track and an ASS subtitle stream. A separate small mixed fixture
supports the native regression suite.

## Metrics and correctness

The principal measured metric is the increase in live allocator bytes from before
input construction to the point where all inputs are retained:
`malloc_zone_statistics(NULL).size_in_use`. Current resident memory is also
sampled using `task_info(MACH_TASK_BASIC_INFO)`. The driver records warm-cache
open/probe/setup wall and process CPU time, but does not calibrate repeated timing
loops; small setup times should be treated as descriptive rather than a stable
latency claim.

All memory and time samples precede semantic verification. Verification then
compares every stored stream/media metadata field, primary font names/MIME/order
and SHA-256 hashes, native codec-private data (including omitted attachment
payloads), initial packets and packets after a seek. Auxiliary Swift font byte
counts are checked separately because their intentional removal is the change
under study. The baseline must retain `F` bytes per auxiliary and the candidate
must retain zero, while both retain the same `F` bytes on the primary input.

These are retained-input component measurements. The driver does not construct
a complete `MediaSession`, decode frames, render subtitle glyphs, or measure
whole-player RSS, FPS, playback CPU, or time to first frame. Native regression
tests separately build the application graph and verify font ownership, stream
and packet parity, executor forwarding, and primary-font subtitle integration.

## Reproduce on macOS

Use the repository's pinned FFmpeg SDK and Swift 6.1 or later:

```sh
python3 Benchmarks/AuxiliaryAttachments/generate-fixtures.py \
  --output /tmp/auxiliary-fixtures
python3 Benchmarks/AuxiliaryAttachments/run.py \
  --fixtures /tmp/auxiliary-fixtures \
  --output /tmp/auxiliary-memory --pairs 8

ILLIQUID_ATTACHMENT_ADMISSION_FIXTURE=/tmp/auxiliary-fixtures/attachment-admission.mkv \
ILLIQUID_AUXILIARY_REAL_FONT_FIXTURE=/tmp/auxiliary-fixtures/real-font.mkv \
  swift test --force-resolved-versions -c release --jobs 2 --no-parallel \
  --filter 'AuxiliaryAttachmentPolicyTests|FontAttachmentAdmissionTests|NativePlaybackFoundationTests'
```

Both output directories must be new or empty. The runner records compiler,
source, native-library and fixture hashes, commands, complete observations,
semantic receipts and paired summaries. The `Auxiliary attachment memory`
workflow runs the native study on the research branch and the regression suite
on relevant pull requests.
