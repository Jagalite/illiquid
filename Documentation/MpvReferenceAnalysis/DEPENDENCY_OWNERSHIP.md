# Dependency ownership

## Decision rule

Delegate parsing, decoding, shaping, and platform rendering only where the
dependency actually owns a complete contract. Superplayr must retain all policy
that spans dependencies: lifecycle, product timeline, queue budgets,
generation/epoch validity, track choice, seek completion, EOF, recovery,
capabilities, diagnostics, and user-visible errors.

## Ownership matrix

| Behavior | mpv | FFmpeg | libass | libplacebo | Apple framework | Superplayr decision |
| --- | --- | --- | --- | --- | --- | --- |
| MKV/MP4 and broad container demux | Coordinates options, stream selection, cache | **Primary parser/packet producer** | — | — | — | Delegate parsing to FFmpeg; own open budgets and playback queues |
| Stream probing and codec parameters | Chooses probe policy and handles partial discovery | **Primary bounded probing**, may decode to discover parameters | — | — | — | Delegate mechanics; add cancellable staged budgets and partial-metadata state |
| Best initial stream | Adds language/default/forced/external/product policy | Generic scoring and decoder availability | — | — | — | Use FFmpeg candidates but implement deterministic product policy |
| Packet references | Pool/cache ownership and reader heads | Produces refcounted `AVPacket` | — | — | — | Wrap/move refs; own byte/time/count queue budgets and backpressure |
| Multiple buffered ranges | **Primary player cache behavior** | No playback range cache | — | — | — | Defer for local files; design a range-capable interface, do not clone mpv cache |
| Timestamp reconstruction | Detects discontinuity and coordinates timeline | **Primary parser/demux heuristics**, best-effort frame timestamps | — | — | Timebase scheduling | Own normalized player timeline, inference diagnostics, and discontinuity policy |
| Codec decode | Policy, wrapper, fallback, frame drop | **Primary codec integration** | — | — | VideoToolbox performs hardware decode | Prefer VT through FFmpeg; own recreation/fallback budgets |
| H.264/HEVC/VP9/AV1 hardware negotiation | Ranks safe methods and retries | Enumerates hardware configs and negotiates format | — | — | **Actual VideoToolbox service** | Inspect supported config, report actual emitted frame path, allow software |
| Hardware-frame lifetime | Keeps device/frame refs through VO | AVFrame/AVBuffer wraps retained CVPixelBuffer | — | Can consume hardware planes in its GPU paths | Retains pixel buffer/sample internally | Own handoff lease and waitable teardown; never infer lifetime from codec flush |
| Decoder reorder and delayed frames | Coordinates send/receive and drain | **Primary codec behavior and API contract** | — | — | — | Implement exact send/receive/drain contract and tag outputs by generation |
| Video format conversion | Chooses/autoinserts converter | swscale/hwframes primitives | — | Rich GPU conversion | Apple accepts pixel buffers/sample descriptions | Keep VT direct path; make software path metadata-explicit and reconfigurable |
| Audio decode/rematrix/resample | Chooses output format, filter chain | **Primary decode and swresample mechanics** | — | — | Output/presentation device | Preserve channel layout; rebuild on input/output changes; Apple owns device clock |
| Playback clock and A/V policy | Manual coordination across AO/VO | Provides timestamps only | — | Frame mixing only when used | Synchronizer/audio renderer provides platform timebase | Let Apple be routine master; Superplayr owns timeline/start/seek/underrun state |
| Playback speed and pitch | Selects filters and compensation | Resample primitive/filter implementations | — | Optional video frame mixing | Audio renderer exposes time-pitch algorithm | Add only after core: Apple time pitch or a dedicated audio processing stage |
| ASS/SSA packet extraction | Routes packets and attachments | Demuxes packet/extradata | **Primary parsing, shaping, effects, layout, glyph rasterization** | Correct overlay color composition when used | — | Direct libass; do not reimplement karaoke/animation/shaping |
| SRT/WebVTT/other text conversion | Coordinates converter then libass | **Primary subtitle decoder/conversion to ASS** | Renders resulting ASS | — | — | Replace ad-hoc SRT parser with FFmpeg subtitle decode/conversion |
| Font attachments/fallback | Validates/routs attachments | Extracts attachment bytes/metadata | **Copies fonts and uses CoreText fallback on macOS** | — | CoreText under libass | Superplayr owns attachment limits, session reset, diagnostics, and teardown order |
| PGS/VobSub/DVB subtitles | Coordinates decoder and regions | **Primary bitmap decoder/state** | Not applicable | Can composite decoded regions | Core Animation/Metal can composite | Implement region compositor after core; capability-gate until then |
| Subtitle delay | Applies product time mapping | — | Renders at caller time | — | — | Own semantics; positive delay must query an earlier subtitle time |
| Scaling/chroma reconstruction | Supplies metadata and renderer settings | Decode output/chroma metadata | — | **Primary rich GPU algorithms** | Opaque platform scaling | Validate Apple first; Metal only if tests fail product thresholds |
| Range/matrix/primaries/transfer | Maps metadata, renderer policy | Extracts/propagates metadata; VT CV attachments | Track has VSFilter matrix hints only | **Explicit color representation and conversion** | Presents/tone-maps based on pixel/sample/layer metadata | P0 metadata propagation and validation; never rely on stale/default attachments |
| Tone/gamut mapping and EDR | User policy | Supplies HDR metadata | Treats subtitle colors as SDR | **Explicit configurable mapping** | Initial platform implementation | Delegate initially to Apple; add explicit renderer only on demonstrated failures |
| Dither/deband/custom scaling | Options and renderer coordination | — | — | **Primary** | Opaque/internal | Optional/deferred; do not implement for parity |
| Deinterlace | Filter selection and field scheduling | Decoder/filter primitives | — | GPU weave/bob/YADIF/BWDIF | May handle some presentation cases opaquely | Detect interlace; validate Apple; add a focused component or mark unsupported |
| Screenshots | Chooses exact frame/time and composition | Encoding primitives | Subtitle masks | Correct render/capture path | Layer snapshot is not a defined media transform | Separate future capture pipeline; no reason alone to replace presenter |
| Seek | **High-level state/policy** | Low-level demux seek and flush; decoder flush primitive | Explicit event flush only when called | — | Renderer flush/timebase | Superplayr owns the whole transaction and completion definition |
| EOF | **High-level drain coordination** | Demux EOF and decoder drain signals | No playback EOF knowledge | Can report render completion only inside its caller | Queues/renderers own samples after enqueue | Superplayr owns per-stage EOF and renderer-drain completion |
| Device hotplug/output failure | Coordinates output policy; ordinary CoreAudio reselects/refreshes and emits hotplug, while exclusive-format changes can request AO reload | Audio conversion only | — | — | **Device and auto-flush notifications** | Observe/serialize, recreate/reprime, and update capabilities |

## Source basis

Key ownership sources at their pinned SHAs:

- `FFmpeg:libavformat/demux.c::avformat_open_input,
  avformat_find_stream_info,read_frame_internal,compute_pkt_fields`;
- `FFmpeg:libavformat/avformat.c::av_find_best_stream`;
- `FFmpeg:libavformat/seek.c::ff_read_frame_flush,avformat_flush`;
- `FFmpeg:libavcodec/avcodec.h::avcodec_send_packet,
  avcodec_receive_frame,avcodec_flush_buffers`;
- `FFmpeg:libavcodec/decode.c::ff_get_format,apply_param_change,
  decode_receive_frame_internal`;
- `FFmpeg:libavcodec/videotoolbox.c::ff_videotoolbox_common_init,
  videotoolbox_decoder_callback,videotoolbox_buffer_create`;
- `FFmpeg:libavutil/hwcontext_videotoolbox.c::av_vt_pixbuf_set_attachments`;
- `FFmpeg:libavcodec/{srtdec,ass,pgssubdec,dvdsubdec,dvbsubdec}.c`;
- `libass:libass/ass.c::ass_process_codec_private,ass_process_chunk,
  ass_flush_events,ass_prune_events`;
- `libass:libass/ass_render.c::ass_render_frame`;
- `libass:libass/ass_shaper.c::ass_shaper_shape`;
- `libass:libass/ass_fontselect.c::ass_font_select` and
  `libass/ass_coretext.c::get_fallback`;
- `libplacebo:src/renderer.c::pass_read_image,pass_scale_main,
  pass_convert_colors,pass_output_target,draw_overlays`;
- `libplacebo:src/colorspace.c::pl_color_space_infer,
  pl_color_repr_decode` and `src/shaders/colorspace.c::pl_shader_color_map_ex`.

See [SOURCE_PINS.md](SOURCE_PINS.md) for the full SHAs and file-license rules.

## Delegation verdicts

### Implement directly in Superplayr

- session/operation/track epochs and stale callback rejection;
- cancellable open lifecycle and product probe budgets;
- timeline normalization and unknown-duration semantics;
- queue budgets, control priority, and backpressure;
- track policy, tri-state selection, and atomic switching;
- seek and EOF state machines;
- presentation leases, renderer status/notification handling, and drain proof;
- typed errors, recovery budgets, diagnostics, and capability reasons;
- subtitle scheduling, viewport, reset, attachment limits, and HDR composition
  policy;
- test-oracle adapters and artifact collection.

### Delegate to FFmpeg

- container/protocol parsing for supported local sources;
- codec discovery, parsing, packet timestamp heuristics, and best-effort frame
  timestamps;
- audio/video decode and reorder/drain mechanics;
- swresample and software pixel conversion primitives;
- VideoToolbox integration and CVPixelBuffer-backed hardware frames;
- conversion of supported text subtitle codecs to ASS;
- PGS/VobSub/DVB bitmap decode.

### Delegate to VideoToolbox and Apple media frameworks

- actual hardware decode;
- the initial renderer, platform timebase, audio-device clock, sample retention,
  routine A/V presentation, and platform tone mapping;
- device and renderer failure signals—but not the policy after those signals.

### Delegate to libass

- ASS/SSA parsing, shaping, font fallback, karaoke/animation, layout,
  collision handling, vector effects, and mask generation.

### Do not adopt yet

- libplacebo/Direct Metal rendering, arbitrary shaders, user LUT ecosystems,
  advanced scaling, frame mixing, debanding, and explicit tone-map controls.

Their value must be proven by the fixture and physical-display gates in
[PICTURE_QUALITY.md](PICTURE_QUALITY.md), not by mpv feature count.
