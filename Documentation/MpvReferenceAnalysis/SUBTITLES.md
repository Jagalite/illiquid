# Subtitles

## Verdict

Retain libass for ASS/SSA rendering, but route non-ASS text through FFmpeg's
subtitle decoders/converter, make seek/track reset explicit, and add an
FFmpeg-decoded bitmap-region compositor after the core refactor. Subtitle timing
and composition are player/presenter responsibilities; libass does not know
about seek generations, EOF, video HDR, or Apple layer state.

## Ownership by subtitle kind

| Kind | Packet/extradata owner | Decode/convert owner | Render owner | Player-owned work |
| --- | --- | --- | --- | --- |
| Embedded ASS/SSA | FFmpeg demux | libass ingests codec private/chunks | libass masks/layout | scheduling, reset, fonts, viewport, composition |
| External ASS/SSA | Superplayr file loader | libass parser | libass | encoding/error UX, lifecycle, track identity |
| SRT/WebVTT/text | FFmpeg demux or file source | **FFmpeg subtitle decoder to ASS** | libass | choose decoder, timestamp mapping, error thresholds |
| PGS | FFmpeg demux | **FFmpeg PGS decoder** | Superplayr region compositor | state reset, canvas/PAR, forced flags, HDR composition |
| VobSub/DVD | FFmpeg demux | **FFmpeg DVD subtitle decoder** | Superplayr region compositor | palette/canvas policy, reset, geometry |
| DVB/teletext/ARIB bitmap | FFmpeg demux | **FFmpeg decoder** | Superplayr region compositor | capability/security limits and product scope |

## What libass actually provides

`ass_process_codec_private` parses Matroska script/style headers.
`ass_process_chunk` parses one Matroska ASS event using caller-supplied start and
duration and normally deduplicates `ReadOrder`. Malformed events are dropped,
not escalated into a playback failure. `ass_flush_events` frees events and resets
duplicate tracking; libass does not call it merely because the player sought.
Optional live-event pruning is off until configured.

Sources: `libass:libass/ass.c::ass_process_codec_private,ass_process_chunk,
ass_flush_events,ass_configure_prune,ass_prune_events @
f9fd3d20dff1cd84b7c74c8ae7f79711ad7736fa` (ISC).

The renderer and its dependencies provide:

- FriBidi paragraph direction/reordering;
- HarfBuzz shaping by direction, script, language, font face, and features;
- CoreText font discovery and per-codepoint fallback on macOS;
- embedded font copies inside the ASS library;
- animation, transforms, fades, scroll, vector drawing, clips, borders,
  shadows, and karaoke;
- event activation at `Start <= time < Start + Duration`;
- layer/ReadOrder ordering, collision placement, mask caching, and linked
  `ASS_Image` alpha-mask output;
- frame/storage size, pixel aspect, margin, font, and style configuration.

Sources: `libass:libass/ass_shaper.c::ass_shaper_shape,
ass_shaper_find_runs`; `libass:libass/ass_coretext.c::get_fallback`;
`libass:libass/ass_fontselect.c::ass_font_select`; `libass:libass/ass_library.c::
ass_add_font,ass_clear_fonts`; `libass:libass/ass_render.c::ass_render_frame`;
`libass:libass/ass_parse.c::ass_apply_transition_effects,
ass_process_karaoke_effects @` the pinned libass SHA (ISC).

Do not reimplement any of those effects in Superplayr.

## What mpv adds

mpv chooses a subtitle decoder from a list. ASS/text uses `sd_ass`; most
non-ASS text formats go through FFmpeg's subtitle decoder and are converted to
ASS chunks before libass. Bitmap codecs use `sd_lavc`, which decodes FFmpeg
`AVSubtitle` regions, converts palettes to BGRA, packs regions, retains bounded
current state, and maps subtitle canvas/PAR into the video viewport.

It loads font attachments by MIME type with extension fallback, preloads text
subtitles when safe, tracks already-seen packets, recognizes animated ASS so it
redraws at the right cadence, and supports a primary and secondary subtitle
track. On reset, the FFmpeg converter is reset. `sub-clear-on-seek` defaults to
false: ordinary ASS reset preserves libass events and ReadOrder deduplication,
while explicit clear-on-seek or `clear_once` flushes events, duplicate state,
and preload state. Subtitle time mapping queries
`videoTime - positiveDelay`, so a positive delay displays a cue later. A
negative delay can require additional future subtitle readahead for lazily
demuxed embedded tracks.

Sources: `mpv:sub/dec_sub.c::init_decoder,pts_to_subtitle,sub_preload,
sub_read_packets,sub_reset`; `mpv:sub/sd_ass.c::add_subtitle_fonts,decode,
get_bitmaps,reset`; `mpv:sub/lavc_conv.c::lavc_conv_create,lavc_conv_decode,
lavc_conv_reset`; `mpv:sub/sd_lavc.c::decode,get_bitmaps,reset`;
`mpv:sub/osd.c::render_object,osd_render @
94335ab87ab225ca3e36e0faeac831639d3e1d4e` (LGPL-2.1-or-later).

Subtitles are not part of `playloop.c::handle_eof`'s A/V barrier.
`player/sub.c::update_subtitles` can continue subtitle policy past video EOF,
and `uninit_sub` clears OSD state before destroying the decoder. OSD libass owns
its renderer/play-resolution mapping and returns bitmap atlases; the
libplacebo-backed VO translates those atlases into overlays for color-aware GPU
composition.

Sources: `mpv:player/sub.c::update_subtitles,uninit_sub`;
`mpv:sub/osd_libass.c::create_ass_renderer,update_playres,
osd_object_get_bitmaps`; `mpv:video/out/vo_gpu_next.c::update_overlays @` the
pinned mpv SHA (LGPL-2.1-or-later for headed files). History for negative delay
and ASS reset is in [SOURCE_PINS.md](SOURCE_PINS.md).

mpv's subtitle queues and options are a behavior catalog, not a design to copy.

## FFmpeg subtitle responsibilities

FFmpeg's SRT decoder parses markup and positioning and emits ASS dialogue under
a generated ASS header. Other text decoders likewise produce `SUBTITLE_ASS`.
This handles packet framing, escaping, encoding-specific details, and placement
that Superplayr's raw UTF-8 conversion misses.

FFmpeg decodes PGS, DVD/VobSub, and DVB subtitles to bitmap rectangles with
palette and timing state. PGS clears object/palette/composition caches at epoch
boundaries and chooses a resolution-sensitive YUV conversion. DVB can infer a
display end and defaults a missing canvas; DVD retains palette/packet state and
flushes it explicitly. Malformed segments are often dropped rather than failing
A/V playback.

Sources: `FFmpeg:libavcodec/srtdec.c::srt_to_ass,srt_decode_frame`;
`FFmpeg:libavcodec/ass.c::ff_ass_subtitle_header_full,ff_ass_add_rect`;
`FFmpeg:libavcodec/pgssubdec.c`; `dvdsubdec.c`; `dvbsubdec.c @
162c2784f90969ae53c1f4aa36d22ef93945a293` (LGPL-2.1-or-later).

libass is not a bitmap subtitle renderer.

## Baseline Superplayr subtitle path (`fbdc699`)

### Embedded text and ASS

`SubtitlePipeline` treats codec names `subrip`, `srt`, `text`, and `webvtt` as
raw UTF-8 text, escapes backslashes/newlines, and wraps each packet in a default
ASS dialogue. It feeds ASS codec-private data and chunks directly to libass.
Packet start uses PTS, then DTS, then zero; missing duration becomes five
seconds. This works for simple fixtures but discards format-specific markup,
positioning, encoding, and parser semantics.

Sources: `Superplayr:Subtitles/SubtitlePipeline.swift::configure,process @
fbdc699627bebf4298a630004ca31a31b0ec5df4`.

Classification: ASS is **functionally close**; other text is **partial** and
should be delegated to FFmpeg.

### External text

External ASS is passed to libass. External SRT is read entirely as UTF-8 and
converted by a custom block parser. Only one external subtitle is supported.
Malformed encodings fail; some valid SRT formatting/positioning will be lost.
The product intake allowlist accepts only `.ass` and `.srt`; external `.ssa`,
WebVTT, and other FFmpeg-decodable text cannot reach the backend through the
normal UI even though the target dependency design can support them.

`loadExternalSubtitle(select:false)` still loads the file and replaces the
active libass track on the first call. Audio/session rebuild can report the
external track as selected while silently reconstructing a default embedded
subtitle and not reloading the external file. Loading external content does not
stop the immutable old embedded-subtitle worker; after it passes its generation
check it can append into the newly replaced shared libass track. `isEnabled` is
also written from backend/main-actor work and read by workers without a common
synchronization boundary, and `eventCount` is read for metrics outside the lock
that protects its mutation.

Sources: `Superplayr:Subtitles/SubtitlePipeline.swift::loadExternal,
convertSRTToASS`; `Production/NativeAppleBackend.swift::loadExternalSubtitle,
replaceSession,emitTracks`; `SuperplayrCore/Utilities/
MediaFileSupport.swift::subtitleFileExtensions,isSupportedSubtitleFile @` the
Superplayr baseline SHA.

Classification: **partial**, with atomic track-state bugs.

### Seek, delay, EOF, and switching

`SubtitlePipeline.clear` only clears render caches and the AppKit overlay. It
does not call `ass_flush_events` or create a replacement track. Events decoded
before a seek therefore remain; reread packets can duplicate or stale future
cues can appear. A long cue beginning before the demux seek point can also be
missing when it was not previously ingested. The generation check before
`process(packet:)` races a concurrent clear/reset.

Positive subtitle delay is added to playback time. mpv's established semantics
subtract a positive delay from the query time. If Superplayr's shared product UI
uses that conventional meaning, the current sign is reversed and makes cues
earlier.

At EOF there is no explicit subtitle drain/clear transition; overlay behavior
depends on the timer and cue duration. Switching embedded subtitle reconstructs
the whole media session instead of flushing/revising just the subtitle decoder.

Sources: `Superplayr:Subtitles/SubtitlePipeline.swift::render,clear`;
`Media/MediaSession.swift::subtitleLoop`; `Production/NativeAppleBackend.swift::
selectSubtitleTrack @` the Superplayr baseline SHA; compare
`mpv:sub/dec_sub.c::pts_to_subtitle` at the pinned mpv SHA.

Classification: seek reset is **missing**; delay is **incorrect unless product
semantics intentionally differ**; EOF/switching are **partial**.

### Fonts

Superplayr extracts likely fonts, calls `ass_add_font`, and uses libass
CoreText/autodetect fallback. `LibassContext.reset` replaces only the track;
registered font identities and library font bytes persist across files. Reopen
of identical data is deduplicated, but distinct fonts accumulate for the
backend's lifetime. The identity uses Swift's process-randomized `hashValue`,
which is fine for in-process dedupe but not diagnostics/reproducibility.

Sources: `Superplayr:Subtitles/FontAttachmentStore.swift`;
`Subtitles/LibassContext.swift::register,reset @` the Superplayr baseline SHA.

Classification: fallback is **delegated/equivalent**; per-session font lifetime
and resource limits are **partial**.

### Bitmap subtitles

PGS, VobSub, and DVB are not supported. They are not routed through FFmpeg's
subtitle decoder, and libass cannot render them.

Classification: **missing**. This is relevant to anime and remux libraries even
though optical-disc navigation is intentionally omitted.

## Geometry, rotation, resize, and HDR

Superplayr supplies libass frame/storage size and translates masks into an
AppKit overlay above the video layer. Video rotation is applied to the video
layer; subtitle text remains upright and the overlay targets the computed video
viewport. Cache invalidation on resize was improved and heavy animated ASS has
performance evidence, but the input video size is still derived from static
stream geometry and physical rotation/display cases remain unqualified.

The AppKit overlay composites libass's SDR colors separately from Apple's HDR
video presentation. libass's `ASS_Track.YCbCrMatrix` is compatibility metadata;
libass explicitly lacks the video color-space context needed for HDR-aware
composition. Subtitle reference white, EDR luminance, gamut mapping, and
alpha-compositing order belong to the presenter. Current subtitles also do not
appear in a media-consistent screenshot/PiP composition path.

Sources: `Superplayr:Subtitles/SubtitleGeometry.swift,SubtitleOverlayView.swift,
LibassContext.swift::configure,render`; `libass:libass/ass_types.h::ASS_Track @`
their pins. Physical gaps are recorded in
`Documentation/NATIVE_PLAYBACK_POC_MANUAL_QUALIFICATION.md` at the Superplayr
baseline.

Classification: resize/ASS rendering is **functionally close**; rotated/HDR/EDR
composition **requires physical-device validation**; HDR correctness is
**missing as an explicit policy**.

## Required subtitle architecture

```text
SubtitleTrackSource
    -> FFmpegSubtitleDecoder (text-to-ASS or bitmap regions)
       -> ASS track -> libass renderer -> SDR mask regions
       -> bitmap track -> timed BGRA/indexed regions
    -> SubtitleScheduler (timeline, delay, primary/secondary policy)
    -> SubtitleCompositor (viewport, rotation, SDR/HDR reference white)
```

State is tagged with `PlaybackEpoch`, `OperationGeneration`, and
`SubtitleTrackRevision`. A seek/track switch performs a serialized transaction:

1. revoke old compositor commit;
2. clear overlay;
3. flush FFmpeg subtitle decoder/converter and `ass_flush_events` or replace the
   track;
4. clear duplicate/preload state;
5. seek/preload enough earlier subtitle packets to recover cues spanning the
   target;
6. accept only matching revision events;
7. render target state and publish completion.

## Policies

| Condition | Superplayr policy |
| --- | --- |
| Malformed single text/ASS packet | Drop cue, structured warning |
| Repeated parser failures | Disable subtitle track; never stop A/V |
| Missing embedded font | CoreText/default fallback + diagnostic |
| Oversized/many font attachments | Enforce per-file bytes/count; ignore excess with warning |
| Track switch init failure | Keep/restore old track if possible; otherwise subtitles off + visible error |
| Unknown duration | Use FFmpeg decoder result/next-cue boundary; avoid arbitrary 5 s when possible |
| PGS/VobSub/DVB before compositor ships | Explicit `unsupported(bitmapSubtitles)` capability |
| Subtitle delay change | Re-evaluate at `mediaTime - delay`; no destructive session rebuild |
| EOF | Keep only cues whose timed interval covers final presentation time, then clear on unload/loop generation |

## Feature scope

Implement one primary text/ASS track, external track loading, correct delay,
seek reset, fonts, then bitmap subtitles. Secondary subtitles are useful but not
required for the first refactor and should remain an explicit omission. Do not
add subtitle scripting, OCR, teletext navigation, or optical-disc menus without
a separate product case.
