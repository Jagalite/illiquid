# Source pins, licensing, and provenance

Inspection date: **2026-07-19**

Superplayr implementation note: the source analysis remains pinned to
`fbdc699627bebf4298a630004ca31a31b0ec5df4`. The FC/IS implementation completed
later at `6825c6b90c9bfdcd3f80391c177edc22a2523513` on 2026-07-20, and the
analysis documents were imported unchanged at `773586f`. Neither later revision
changes the external oracle pins or retroactively changes a baseline citation.
Current implementation and qualification claims must cite
[FCIS_COMPLETION_MATRIX.md](../FCIS_COMPLETION_MATRIX.md) and
[NATIVE_PLAYBACK_QUALIFICATION.md](../NATIVE_PLAYBACK_QUALIFICATION.md), not the
2026-07-19 source descriptions alone.

The full commit SHA is normative. Tags and version strings are descriptive and
may move, omit post-release commits, or disagree with a development branch's
embedded version text.

## Analyzed revisions

| Project | Repository | Exact revision | Version description | Commit date | Relevant licensing |
| --- | --- | --- | --- | --- | --- |
| Superplayr | local checkout; no Git remote configured | `fbdc699627bebf4298a630004ca31a31b0ec5df4` | `main` | 2026-07-19 | No top-level license file was present in the inspected checkout; do not infer distribution terms |
| mpv | <https://github.com/mpv-player/mpv.git> | `94335ab87ab225ca3e36e0faeac831639d3e1d4e` | `git-release-159-g94335ab87a`; release-base describe `v0.41.0-878-g94335ab87a` | 2026-07-14 | GPL-2.0-or-later by default; the program can be LGPL-2.1-or-later only when built without GPL-only files. `-Dgpl=false` is a convenience switch, not itself a license grant, and linked libraries affect the result |
| FFmpeg | <https://github.com/FFmpeg/FFmpeg.git> | `162c2784f90969ae53c1f4aa36d22ef93945a293` | unreleased `master`; source `RELEASE` says `8.0.git` | 2026-07-19 | Mostly LGPL-2.1-or-later; enabling GPL components changes the combined build; `--enable-nonfree` combinations are not redistributable under FFmpeg's terms |
| libass | <https://github.com/libass/libass.git> | `f9fd3d20dff1cd84b7c74c8ae7f79711ad7736fa` | `0.17.5-2-gf9fd3d2` | 2026-07-11 | ISC |
| libplacebo | <https://github.com/haasn/libplacebo.git> | `a7a18af88ff0a17c04840dcb3246047bb6b46df3` | project version `7.371.0`; nearest tag `v7.360.0` | 2026-07-08 | LGPL-2.1-or-later; individual public headers may offer other terms, which do not automatically cover implementations |
| Apple media frameworks | macOS 26.5 SDK installed with the inspected toolchain | SDK headers, not a Git revision | macOS SDK 26.5 | inspected 2026-07-19 | Proprietary Apple platform APIs and SDK terms |

The external Git checkouts are at `/tmp/superplayr-reference-src/{mpv,ffmpeg,libass,libplacebo}`.
That path is outside the production repository and is neither a build input nor
a Git-tracked source target. The checkouts began shallow/partial; mpv history was
expanded where blame and commit rationale were required. A future rerun should
fetch the exact SHA directly and verify it before analysis.

## Runtime baseline versus reference pins

The reference revisions above are not necessarily the binaries linked by the
current Superplayr build. The inspected machine reported:

| Component | Installed/build-visible value |
| --- | --- |
| Homebrew FFmpeg | `8.1.2` |
| libavformat / libavcodec / libavutil | `62.12.102` / `62.28.102` / `60.26.102` |
| libswscale / libswresample | `9.5.102` / `6.3.102` |
| Homebrew libass | `0.17.5` |
| Homebrew mpv | `0.41.0_6` |
| Swift | Apple Swift `6.3.2` |
| macOS SDK | `26.5` |

`Package.swift` currently obtains FFmpeg, libass, and mpv through system-library
`pkg-config` discovery rather than immutable binary pins. Differential results
must therefore record both the source-oracle SHA and the actual executable or
dynamic-library hashes used in each run.

## Superplayr baseline inputs and drift check

The analysis used all requested local evidence, then verified material claims
against `fbdc699627bebf4298a630004ca31a31b0ec5df4`:

| Input | What it contributed | Current-source disposition |
| --- | --- | --- |
| `architecture-implementation-state-report.txt` | Original libmpv/OpenGL topology and the rationale for a native POC; inspected HEAD `d361d4c75510016f36d4102319bee39ac7eb9a44` | Historical. Its “no native pipeline” conclusion predates the current native POC and production integration |
| `Documentation/ARCHITECTURE.md` | Product/core/player/app separation and legacy lifecycle contracts | Still useful for product boundaries, but its playback description is legacy-backend-centric |
| `Documentation/NATIVE_PLAYBACK_POC_REPORT.md` | Implemented FFmpeg, VideoToolbox, sample-buffer, queue, generation, and libass design | Verified against current sources; feasibility evidence does not establish every production semantic invariant |
| `Documentation/NATIVE_PLAYBACK_POC_MANUAL_QUALIFICATION.md` | Long-run, fullscreen, P010, and subtitle-render evidence plus outstanding physical checks | Results remain evidence from 2026-07-18; current HEAD was not assumed to inherit them without rerun |
| `Documentation/PRODUCTION_PLAYBACK_INTEGRATION_REPORT.md` | Backend seam and native integration scope | Verified; it correctly records legacy as the then-default path, while this plan explicitly removes that path after native acceptance |
| `Tests/`, `Scripts/generate-native-poc-fixtures.sh`, and native diagnostics | Existing assertions, generated fixtures, and qualification metrics | Inspected directly; gaps in semantic assertions are recorded in the fixture plan and gap matrix |

The untracked architecture-state report is an input only. This analysis did not
edit, move, stage, or otherwise adopt it into the documentation set.

## Inspected source surfaces

### mpv

At minimum, this study inspected:

- `DOCS/tech-overview.txt`;
- `player/{playloop,loadfile,command,client}.c` and `player/core.h`;
- `demux/demux.c`, `demux/demux_lavf.c`, and related packet/cache structures;
- `filters/f_decoder_wrapper.c`, `f_output_chain.c`, and `f_autoconvert.c`;
- `video/decode/vd_lavc.c`, video output and GPU/libplacebo integration;
- `audio/decode/ad_lavc.c`, audio filters, `player/audio.c`, `audio/out/ao.c`,
  `audio/out/buffer.c`, `audio/out/ao_avfoundation.m`,
  `audio/out/ao_coreaudio.c`, and `audio/out/ao_coreaudio_exclusive.c`;
- `sub/dec_sub.c`, `sd_ass.c`, `sd_lavc.c`, `lavc_conv.c`, `osd.c`, and
  `osd_libass.c`;
- tests, file history, blame, documented options, and the issues below.

Most listed player/demux/decode/output/subtitle C files carry
LGPL-2.1-or-later headers. `player/client.c` carries an ISC-style header.
Files without a local header require consulting mpv's `Copyright` and repository
history; absence of a header is not permission to copy.

Embedded provenance exceptions matter even inside otherwise LGPL-oriented mpv
surfaces: `audio/filter/af_scaletempo2_internals.{h,c}` was ported from Chromium
revision `51ed77e3f37a9a9b80d6d0a8259e84a8ca635259` and its header carries
BSD-3-Clause terms;
`sub/lavc_conv.c::parse_webvtt` records a copied/modified FFmpeg origin under
LGPL-2.1-or-later; and `sub/sd_lavc.c::step_sub` records an ISC libass origin.
Any later adaptation review must inspect the exact function's header/comment
and original project, not infer terms from the surrounding directory.

### FFmpeg

Inspection was intentionally ownership-driven, principally:

- `libavformat/{demux,avformat,seek}.c`;
- `libavcodec/{avcodec,decode,videotoolbox,srtdec,ass,pgssubdec,dvdsubdec,dvbsubdec}.c`;
- codec-specific VideoToolbox glue;
- `libavutil/hwcontext_videotoolbox.{c,h}`;
- public send/receive/flush contracts in `libavcodec/avcodec.h`.

These inspected core files are under FFmpeg's LGPL terms at the pin, but the
license of a distributed FFmpeg artifact depends on its complete configure and
dependency closure.

### libass

Inspection covered event parsing and reset (`libass/ass.c`), renderer and ASS
effects (`ass_render.c`, `ass_parse.c`), shaping (`ass_shaper.c`), font selection
and CoreText fallback (`ass_fontselect.c`, `ass_coretext.c`), and render API/type
contracts. libass is ISC licensed at the pin.

### libplacebo

Inspection covered `src/renderer.c`, `src/colorspace.c`, color-space shaders,
sampling, dithering, debanding, deinterlacing, overlays, and public parameter
defaults. libplacebo is a rendering reference only; it is not a proposed runtime
dependency in the initial refactor.

## History and issue evidence

Current comments explain most unusual checks. The following primary history was
also used where rationale matters:

| Reference | Why it matters |
| --- | --- |
| mpv commit [`57fbc9cd76f7a78f1034c42dd3c453ff35123264`](https://github.com/mpv-player/mpv/commit/57fbc9cd76f7a78f1034c42dd3c453ff35123264), fixing [issue #7206](https://github.com/mpv-player/mpv/issues/7206) | A queued exact seek must not reset state before A/V has conclusively published EOF; otherwise repeated near-EOF seeks can suppress playlist advancement |
| mpv [pull request #13663](https://github.com/mpv-player/mpv/pull/13663) and commit [`ab419a6660c6f8f78b30ba0838ab3c274746af89`](https://github.com/mpv-player/mpv/commit/ab419a6660c6f8f78b30ba0838ab3c274746af89), fixing [issue #11617](https://github.com/mpv-player/mpv/issues/11617) | CoreAudio reset is fast for wireless pause/seek, but leaving the AudioUnit running consumes CPU and prevents sleep; mpv delays the actual stop |
| [mpv issue #6546](https://github.com/mpv-player/mpv/issues/6546) | A historical VideoToolbox full-range error was traced to FFmpeg/VideoToolbox pixel-format integration, illustrating why ownership and exact dependency versions matter |
| [mpv issue #6749](https://github.com/mpv-player/mpv/issues/6749) | VideoToolbox session availability can be a platform/resource limit; software fallback is required even when the codec is normally supported in hardware |
| mpv commits around `demux/demux.c`, including `4e750e31a1a68f941a5e2ce53c30cdc5ac7a7ca2`, `e6911f82a579f202765fc382d219447c686d8e54`, `d25fbb081387ddb9679a31faf43946ad837c5d66`, and `18d38d4f3ed7658d40c1a8cc496d60d414fbef36` | Cached-range EOF, range joining, backward seeks, and beginning-of-file flags were repeatedly hardened; Superplayr should adopt explicit invariants, not copy the cache implementation |
| mpv commits [`c000b37e9abd926fffff79c4f3056e1700a0e849`](https://github.com/mpv-player/mpv/commit/c000b37e9abd926fffff79c4f3056e1700a0e849) ([#3914](https://github.com/mpv-player/mpv/issues/3914)) and [`fbd0be1cf4435c303d764a0ceddab323b96d7ba7`](https://github.com/mpv-player/mpv/commit/fbd0be1cf4435c303d764a0ceddab323b96d7ba7) ([#11947](https://github.com/mpv-player/mpv/issues/11947)) | Hardware fallback may need retained/replayed probe packets and repeated candidate selection before software succeeds |
| mpv commit [`7ec8a7e9b1c5a25d1b70037b1a0593b833d217b8`](https://github.com/mpv-player/mpv/commit/7ec8a7e9b1c5a25d1b70037b1a0593b833d217b8) ([#17484](https://github.com/mpv-player/mpv/issues/17484)) | After hardware-decoder reinitialization, unsafe pre-keyframe input can falsely condemn the new decoder; mpv bounds keyframe waiting to 96 packets |
| mpv commit [`cf2b7a4997299ff9e0ff91d4273cd294686b001f`](https://github.com/mpv-player/mpv/commit/cf2b7a4997299ff9e0ff91d4273cd294686b001f) ([#7484](https://github.com/mpv-player/mpv/issues/7484)) | Negative subtitle delay can require additional future subtitle readahead for lazily demuxed embedded tracks |
| mpv commits [`044af63d98b926fc6d4dd32068476707fd0bce88`](https://github.com/mpv-player/mpv/commit/044af63d98b926fc6d4dd32068476707fd0bce88) and [`b56e2efd5f3d2ed5e62fe02acdaedef03b2d2fbc`](https://github.com/mpv-player/mpv/commit/b56e2efd5f3d2ed5e62fe02acdaedef03b2d2fbc) | EOF clearing has stream-specific exceptions, and ordinary EOF does not imply an appended-file follow policy |
| mpv commit [`0f2370476b4279040261878c601fb8015a8502d7`](https://github.com/mpv-player/mpv/commit/0f2370476b4279040261878c601fb8015a8502d7) | ASS seek/reset behavior deliberately preserves or prunes events depending on subtitle duration and deduplication semantics |

The issue discussions are behavioral evidence from older versions, not proof
that the pinned revision still contains the reported bug. Current source was
used to determine present behavior.

## Citation and adaptation policy

Detailed source-derived findings name project, file, relevant function/type,
and pinned SHA. Summary matrices may use evidence keys that expand to those
source lists. Findings are descriptions in original language; they are not
transliterations of control flow.

Rules for later implementation:

1. Treat these documents as requirements and test ideas, not code templates.
2. Do not copy implementation fragments from any reference project.
3. If direct adaptation is ever proposed, isolate it in a separate review,
   record origin file/function/commit and its file license, preserve notices,
   and obtain legal approval before merging.
4. Record `avcodec_configuration()`, package build flags, binary hashes, and
   notices for every distributed FFmpeg build.
5. Linking libplacebo later would be a new LGPL distribution decision even
   though this analysis currently uses it only as a behavioral reference.
6. Apple framework behavior is OS-, device-, and display-dependent. Header
   contracts are not substitutes for the physical validation matrix.
7. The current Superplayr checkout has no top-level license file. Resolve the
   product's own licensing posture before evaluating any direct adaptation.

No substantial external source was copied into these documents or into
Superplayr.
