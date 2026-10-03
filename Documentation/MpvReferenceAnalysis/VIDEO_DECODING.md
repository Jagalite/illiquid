# Video decoding

## Verdict

Retain FFmpeg's decoder API and VideoToolbox integration. Replace the current
binary “configured hardware” flag and broad fallback-on-any-error behavior with
actual hardware-format observation, typed failure classification, a bounded
consecutive-failure budget, and a generation-safe software decoder replacement. Presenter
reconfiguration must follow emitted frames, not only container metadata.

## Behavior and ownership

| Behavior | True owner | mpv's role | Superplayr current state |
| --- | --- | --- | --- |
| Codec implementation | FFmpeg decoder | chooses/ranks decoder | delegated |
| VT session and decode | FFmpeg glue + VideoToolbox | chooses safe method and supplies device | configured through FFmpeg |
| Pixel-format negotiation | FFmpeg `get_format` contract + app callback | validates method and retries candidates | callback prefers VT, then first format |
| Reordering/delayed frames | FFmpeg | correct send/receive/drain use | partial |
| Runtime hardware fallback | player policy | counts failure, retries next HW then software, can requeue probe packets | first two consecutive HW decode failures resume FFmpeg/VT; the third triggers the lineage's one SW rebuild and replays a bounded keyframe GOP without seeking audio/presentation |
| Dynamic size/pixel/color | decoder frame + player/output | detects and reconfigures filter/VO | size stored per frame; geometry/resampler/presenter policy incomplete |
| Frame dropping | player scheduling + decoder discard flags | sync-aware predecode and presentation drop | no lateness-based decode drop |
| Frame lifetime | FFmpeg refs + output refs | holds through VO | retained CVPixelBuffer is sound; shared sink epoch is not |

## FFmpeg decoder contract

A packet is sent once. The decoder can produce zero or more frames; the caller
receives until `EAGAIN`, then sends again. Both sides cannot legitimately return
`EAGAIN` simultaneously. A successful send consumes the whole packet
semantically while retaining/copying any internal reference it needs.

At input EOF, send a null packet and receive until `AVERROR_EOF`. Drain is sticky;
reuse requires `avcodec_flush_buffers`. Flush resets decoder drain, buffered
packet/frame, timestamp-correction, bitstream-filter, threading, and codec state,
but caller-held `AVFrame` references remain valid. App queues and Apple samples
are therefore not invalidated by decoder flush.

Sources: `FFmpeg:libavcodec/avcodec.h::avcodec_send_packet,
avcodec_receive_frame,avcodec_flush_buffers`;
`FFmpeg:libavcodec/decode.c::avcodec_send_packet,
decode_receive_frame_internal @ 162c2784f90969ae53c1f4aa36d22ef93945a293`
(LGPL-2.1-or-later).

FFmpeg applies packet-side dimension/sample/channel changes only for codecs
advertising `AV_CODEC_CAP_PARAM_CHANGE`. It validates malformed side data. The
application must still compare actual output frame properties because codec
headers, hardware surfaces, and color metadata can change without a complete
container-track replacement.

Source: `FFmpeg:libavcodec/decode.c::apply_param_change,frame_validate,
apply_cropping @` the pinned FFmpeg SHA (LGPL-2.1-or-later).

## VideoToolbox behavior

FFmpeg's VideoToolbox path builds codec-specific `CMVideoFormatDescription`
atoms and a `VTDecompressionSession`. It generally requires hardware
acceleration for supported codecs, with codec-specific preference/permitted
flags. It maps depth/subsampling to NV12, P010, and supported 4:2:2/4:4:4 pixel
formats. The Apple service performs decode.

Important recovery behavior already below Superplayr:

- reference-missing callback status can produce no output without forcing a
  session reset;
- invalid-session/decode-malfunction statuses invalidate the VT session and
  request recreation on the next frame;
- actual output `CVPixelBuffer` format/width/height rebuilds FFmpeg's cached
  hardware frames context;
- a hardware frame retains both its pixel buffer and hardware frames context
  until the AVFrame buffer is released.

Sources: `FFmpeg:libavcodec/videotoolbox.c::ff_videotoolbox_common_init,
videotoolbox_start,videotoolbox_best_pixel_format,
videotoolbox_decoder_callback,videotoolbox_session_decode_frame,
videotoolbox_buffer_create,videotoolbox_buffer_release @` the pinned FFmpeg SHA
(LGPL-2.1-or-later).

Thus a single VT error should not automatically cause an application-level
software fallback. First let FFmpeg's internal session invalidation/recreation
path run; FFmpeg does not document a one-attempt bound, so the surrounding
player must impose its own observed-failure budget. Initial
`kVTVideoDecoderNotAvailableNowErr` is a resource/platform condition and should
fall back immediately. Historical mpv issue #6749 demonstrates that a codec
supported in principle can still lack an available session.

## mpv's extra decoder policy

Pinned mpv defaults to `hwdec=no`. Once hardware decoding is enabled, it
enumerates hardware configurations, sorts direct before copy modes, checks codec
allowlists and device capability, avoids methods already attempted, and
eventually chooses software. The pinned default failure threshold is three
hardware decode errors. During early hardware probing it retains a bounded set
of sent packets so a newly selected decoder can replay the necessary access
units. After hardware-decoder reinitialization, `send_packet` drops at most 96
non-key packets while waiting for a safe keyframe, avoiding false failure from
predictable pre-keyframe errors without waiting forever.

Superplayr now applies the same ownership principle at runtime fallback: it
retains one bounded GOP from the latest compressed-video keyframe. A software
replacement replays those packets behind the already-submitted video horizon
while the audio clock and subtitle worker remain live. Only an unavailable or
over-budget GOP uses the slower exact-seek recovery path.

Once software decoding is active, libavcodec packet/receive errors caused by
damaged access units are counted and dropped instead of re-entering player-level
recovery. Out-of-memory and application-owned conversion/allocation failures
still propagate. Frames explicitly marked corrupt are also discarded. This
matches mpv's default `vd-lavc-show-all=no` outcome: corruption may be logged,
but recognized broken output is not presented and later packets keep flowing.

It also:

- resets hardware failure count after a successful frame;
- treats hardware download failure as a reason to fall back;
- detects changed static/dynamic image parameters in the decoder wrapper;
- drains converter state before swapping formats where possible;
- applies decoder discard levels for high-resolution seek and lateness drop;
- detects non-positive or extreme PTS-derived frame duration as a discontinuity.

Sources: `mpv:video/decode/vd_lavc.c::select_and_set_hwdec,reinit,
get_format_hwdec,handle_err,send_packet,receive_frame`;
`mpv:filters/f_decoder_wrapper.c::fix_image_params,process_output_frame,
correct_video_pts`; `mpv:filters/f_autoconvert.c::handle_video_frame`;
`mpv:player/video.c::check_framedrop,handle_new_frame @` the pinned mpv SHA
(LGPL-2.1-or-later for headed files).

History: mpv commit
`7ec8a7e9b1c5a25d1b70037b1a0593b833d217b8` fixed issue #17484 by adding the
bounded post-reinit keyframe wait. Full links and provenance are in
[SOURCE_PINS.md](SOURCE_PINS.md).

These are behavioral references. Superplayr needs only VideoToolbox and
software at first, not mpv's platform-neutral hardware-method table.

## Baseline Superplayr decoder (`fbdc699`)

### Initial setup

`superplayr_create_decoder` finds FFmpeg's default decoder, creates a
VideoToolbox device, and installs a callback selecting
`AV_PIX_FMT_VIDEOTOOLBOX` when offered. If `avcodec_open2` fails, it creates one
software context. It does not first enumerate `avcodec_get_hw_config`, and the
reported `using_hardware` means “a hardware device was configured,” not “a
hardware frame was emitted.” Product status later treats some software status
names as hardware.

Source: `Superplayr:Sources/CFFmpeg/include/ffmpeg_shim.h::
superplayr_create_decoder,superplayr_videotoolbox_get_format`;
`SuperplayrPlayer/Player/
PlaybackController.swift`; `SuperplayrCore/Player/PlaybackModels.swift @` the
Superplayr baseline SHA.

Classification: decode setup is **functionally close** for common fixtures;
capability/status reporting is **incorrect**.

The callback's no-VideoToolbox branch returns `formats[0]` rather than asking
FFmpeg's default selector for a supported software format. Treat FFmpeg's
ordered format list as a negotiation contract, not an assumption that the first
entry is always the desired software choice. A replacement callback must
validate the actual selected format and preserve a safe software candidate.

Decoder drain is also concretely incomplete. Video and audio accept
`avcodec_send_packet(nil) == EAGAIN`, receive available frames once, and then
publish decoded EOF without resending the null packet until
`avcodec_receive_frame` reaches `AVERROR_EOF`. A delayed decoder can therefore
lose tail frames. The refactor must loop the full send-null/receive contract.

### Frames and lifetime

For VT output, `VideoDecoder` retains the `CVPixelBuffer` from `AVFrame.data[3]`
before unrefing the frame. That is the correct ownership boundary. For software
output, it allocates an IOSurface-backed BGRA buffer and uses a cached bilinear
swscale context. The software path always reduces to 8-bit BGRA, losing 10-bit
precision and making color conversion behavior depend on swscale defaults.

Source: `Superplayr:Media/VideoDecoder.swift::makeFrame` and
`CFFmpeg/include/ffmpeg_shim.h::superplayr_copy_frame_to_bgra_pixel_buffer @` the
Superplayr baseline SHA.

Classification: VT lifetime is **equivalent at the application handoff**;
software high-bit-depth/color fidelity is **partial**.

### Timing and metadata

PTS uses FFmpeg's best-effort timestamp. Missing frame duration falls back to a
static average frame rate, then 1/30 second. That is not safe for VFR and can
mask missing timing. Actual decoded width/height is recorded, but display size,
the Swift `pixelAspectRatio`, and rotation derive from the static stream
snapshot. On the VT path, however, pinned FFmpeg already applies the emitted
frame's pixel aspect, chroma location, colorspace, and range-associated pixel
format to the returned CVPixelBuffer through `av_vt_pixbuf_set_attachments`.
Superplayr then adds common primaries, transfer, matrix, mastering-display, and
content-light attachments. It neither inspects nor proves the full effective
attachment set, and its app-created software BGRA buffer does not receive an
equivalent aspect/chroma/aperture policy. Software BGRA also receives a YCbCr-
matrix attachment even though the buffer is RGB.

Sources: `Superplayr:Media/VideoDecoder.swift::makeFrame,
applyColorMetadata`; `Media/FFmpegStreamInfo.swift @` the baseline SHA;
`FFmpeg:libavcodec/videotoolbox.c::videotoolbox_postproc_frame` and
`libavutil/hwcontext_videotoolbox.c::av_vt_pixbuf_set_attachments @` the pinned
FFmpeg SHA.

Classification: **partial**; requires generated color-patch tests and physical
device validation.

### Runtime failure and format changes

Any thrown hardware decode or frame-conversion error invokes
`switchToSoftware`, advances generation, and seeks to the sampled presentation
time. This is bounded once, which avoids retry loops, but it conflates corrupt
packets, transient VT state, bad frame metadata, allocation failure, and actual
persistent hardware failure. The software context replacement is sound in
isolation but the recovery can race a new session and flush its shared
presentation state.

The audio resampler is unrelated but illustrates the same format-change issue:
it is created once. Video makes a new CoreMedia format description per frame,
which tolerates some size changes, but viewport/static geometry and an atomic
renderer reconfiguration transaction are absent.

Source: `Superplayr:Media/MediaSession.swift::
recoverVideoDecoderFromHardwareFailure`;
`Media/VideoDecoder.swift::switchToSoftware`; presentation sources at the
Superplayr baseline SHA.

Classification: fallback is **partial**; midstream reconfiguration is
**requires real-media validation** and structurally incomplete.

The advertised hardware-decoding policy is also only **partial**. Calling
`NativeAppleBackend.setHardwareDecodingPolicy` mutates `preferHardware`, which
is consumed when a later `MediaSession` is constructed; it does not rebuild the
active decoder. `automatic` and `compatibility` both select the same preferred
VideoToolbox-with-software-fallback path. Until there is an explicit decoder
revision transaction, the command and capability must say “next load” rather
than implying that the active session changed.

Source: `Superplayr:Production/NativeAppleBackend.swift::
setHardwareDecodingPolicy,replaceSession @` the Superplayr baseline SHA.

## Required decoder invariants

1. Never drop a packet merely because send returned `EAGAIN`; drain output and
   resend the same owned packet.
2. At demux EOF, keep retrying the null send after receive-side `EAGAIN` until
   the decoder accepts it, then receive through decoder EOF before publishing
   decoded EOF. Only one null send may be outstanding at a time.
3. Decoder flush never stands in for app-queue, renderer, or generation reset.
4. A frame carries `PlaybackEpoch`, `OperationGeneration`, and `TrackRevision`.
5. Presenter configuration keys off actual emitted width, height, pixel format,
   SAR, rotation revision, range, matrix, primaries, transfer, chroma location,
   and HDR side data.
6. A configuration change suspends enqueue, drains or flushes the old
   presentation revision, atomically installs the new format, then resumes.
7. Hardware status is true only after an actual VT-backed frame; “configured,”
   “active,” “recreating,” and “software fallback” are separate diagnostics.
   A no-VT negotiation path selects a validated software format rather than
   blindly accepting the first offered entry.
8. Initial VT unavailable or incompatible falls back immediately. Runtime VT
   invalidation gets one bounded recreation; recurrence rebuilds software under
   a new generation.
9. Isolated corrupt packet/frame errors are skipped and counted. Only sustained
   errors cross the track-disable/terminal threshold.
10. Fallback resumes from a keyframe/preroll boundary and never lets an old
    hardware frame commit after software generation begins.
11. Frame references remain alive through sample creation/enqueue and any Apple
    retention contract; teardown waits or revokes the presentation lease.

## Policy by failure

| Failure | Policy |
| --- | --- |
| Unsupported codec/no decoder | Disable that track; if no playable A/V remains, user-visible unsupported error |
| `avcodec_open2` with VT fails | Recreate software immediately |
| VT unavailable now/resource limit | Software fallback; structured platform/resource diagnostic |
| VT invalid session/malfunction | Let FFmpeg recreate once; repeated fault replaces decoder in software |
| One corrupt packet/frame | Skip and increment per-codec counter |
| Sustained corruption | Keyframe recovery once; then disable affected track or stop if it is the only required media |
| New resolution/pixel format/color revision | Atomic presenter reconfiguration; stop with clear error if unsupported |
| Hardware-frame download/conversion failure | Prefer direct VT presentation; if a required conversion cannot work, software fallback once |
| Allocation failure | Stop the affected session; do not retry in a memory-pressure loop |
| Invalid frame structure | Skip/count; bounded terminal threshold |

## Feature scope

Implement rotation, SAR, dynamic size/color correctness, VT/software fallback,
and limited interlace detection. Defer user decoder selection, arbitrary video
filters, reverse playback, and broad hardware API abstraction. Do not add a
Metal presenter merely to copy mpv's decoder-output flexibility.

## Implemented production hardening (2026-08-09)

Superplayr now applies the relevant mpv/IINA lessons without introducing
libmpv as a runtime dependency:

- `av_read_frame` recovery is bounded by error class, retry count, and elapsed
  no-progress time; EOF and interruption remain distinct outcomes.
- VideoToolbox is requested only when FFmpeg advertises a matching hardware
  configuration and the current Mac reports codec support. Negotiation selects
  an explicit software format if hardware output is unavailable.
- Sparse decoder corruption is dropped and counted. Sustained software-video
  corruption receives one keyframe-based decoder restart before terminal
  escalation, with the streak reset by every successful frame.
- Decoded float audio is sanitized for non-finite and subnormal samples.
  Sustained audio corruption disables audio only when video remains.
- Subtitle input failure disables only the optional subtitle track.
- Audio-renderer failure escalates through flush, renderer replacement, and
  finally video-only playback.
- Presentation revisions include actual decoded-frame SAR, crop/aperture,
  rotation, chroma location, and HDR payloads. Timestamp validation drops small
  backward regressions and turns large jumps into presentation discontinuities.
