# Superplayr gap matrix

Baseline: Superplayr `fbdc699627bebf4298a630004ca31a31b0ec5df4`, inspected
2026-07-19. The row-level classifications below intentionally remain the dated
baseline and should not be read as current implementation status.

## Current reconciliation (2026-07-20)

The FC/IS authority migration completed at `6825c6b`. Global effect identity,
core-owned seek/recovery/synchronization/drain/track/subtitle policy, native
fences and leases, reactive projection, waitable production outcomes, and the
native-only package are current implementation facts. See
[FCIS_COMPLETION_MATRIX.md](../FCIS_COMPLETION_MATRIX.md).

The completion run also closed the migration verification gate with 119 tests
in 20 suites, hostile production-driver outcome tests, architecture validation,
fresh ASan/TSan 12-reopen stress, three 60-second zero-drop A/V soaks,
package/signature verification, and live packaged-app smoke. See
[NATIVE_PLAYBACK_QUALIFICATION.md](../NATIVE_PLAYBACK_QUALIFICATION.md).

Do not bulk-promote the baseline rows to “complete.” Many describe a mixture of
authority, mechanism, fixture, and physical evidence. The authority portion is
complete; these categories remain open unless current tests or qualification
explicitly prove them:

- a pinned mpv/FFprobe runner, normalized result schema, comparator, and retained
  differential artifacts;
- self-verifying VFR/timestamp/corrupt/truncated/format-change/color/subtitle
  fixtures and their semantic assertions;
- visible/audible presentation evidence beyond submission-level proxies where
  Apple does not expose a hard fact; and
- the full supported display, HDR/SDR, audio-route/device, sleep/wake, and PiP
  release matrix.

## Classification legend

- **Equivalent**: same relevant behavioral contract for the scoped macOS product.
- **Functionally close**: ordinary behavior matches; bounded edge work remains.
- **Partial**: useful implementation exists but a named required contract is
  absent or incorrect.
- **Missing**: no effective implementation.
- **Intentionally unsupported**: explicit product omission, not a defect.
- **Delegated to a dependency**: complete enough to rely on the named owner;
  Superplayr still coordinates it.
- **Requires real-media validation**: source looks plausible but synthetic/unit
  evidence is insufficient.
- **Requires physical-device validation**: behavior depends on Mac/audio/display
  hardware or visible output.

Each row has one primary classification. The action column can require tests or
delegation in addition to that classification.

## Evidence keys

All Superplayr keys refer to
`fbdc699627bebf4298a630004ca31a31b0ec5df4`; mpv to
`94335ab87ab225ca3e36e0faeac831639d3e1d4e`; FFmpeg to
`162c2784f90969ae53c1f4aa36d22ef93945a293`; libass to
`f9fd3d20dff1cd84b7c74c8ae7f79711ad7736fa`; and libplacebo to
`a7a18af88ff0a17c04840dcb3246047bb6b46df3`.

| Key | Project, file, relevant symbols |
| --- | --- |
| `SP-DMX` | Superplayr `Media/FFmpegDemuxer.swift::init,readPacket,seek,makeMediaInfo` |
| `SP-SES` | Superplayr `Media/MediaSession.swift::init,seek,demuxLoop,videoDecodeLoop,audioDecodeLoop,videoPresentationLoop,audioPresentationLoop,markEnded,recoverVideoDecoderFromHardwareFailure` |
| `SP-VID` | Superplayr `Media/VideoDecoder.swift::decode,drain,makeFrame,switchToSoftware,applyColorMetadata` and `CFFmpeg/include/ffmpeg_shim.h` |
| `SP-AUD` | Superplayr `Media/AudioDecoder.swift::decode,drain,convert` and audio resampler shim |
| `SP-PRES` | Superplayr `Presentation/NativePresentationCoordinator.swift`, `SampleBufferVideoPresenter.swift`, `SampleBufferAudioPresenter.swift`, `NativePlayerView.swift` |
| `SP-SUB` | Superplayr `Subtitles/SubtitlePipeline.swift`, `LibassContext.swift`, `SubtitleOverlayView.swift` |
| `SP-BE` | Superplayr `Production/NativeAppleBackend.swift::load,seek,selectAudioTrack,selectSubtitleTrack,loadExternalSubtitle,replaceSession,tick,shutdown` |
| `SP-GEN` | Superplayr `Playback/PlaybackGeneration.swift`, `SeekCoordinator.swift`, `PacketQueue.swift` |
| `SP-PROD` | Superplayr `SuperplayrPlayer/Player/PlaybackController.swift`; core playback models/state/capabilities |
| `SP-TEST` | Superplayr native fixture generator, foundation/integration tests, POC reports, manual qualification |
| `MPV-PLAY` | mpv `player/core.h`; `player/playloop.c::mp_seek,queue_seek,execute_queued_seek,handle_playback_restart,handle_eof,run_playloop` |
| `MPV-LOAD` | mpv `player/loadfile.c::play_current_file,compare_track,select_default_track,update_demuxer_properties,uninit_demuxer,kill_demuxers_reentrant,cancel_open` |
| `MPV-DMX` | mpv `demux/demux.c::add_packet_locked,read_packet,find_seek_target,attempt_range_joining,update_seek_ranges,demux_get_reader_state`; `demux_lavf.c` |
| `MPV-VID` | mpv `video/decode/vd_lavc.c::select_and_set_hwdec,send_packet,receive_frame`; `filters/f_decoder_wrapper.c::feed_packet,process_output_frame`; `player/video.c::check_framedrop,write_video`; `video/out/vo.c::vo_queue_frame,vo_seek_reset,vo_wait_frame,vo_destroy` |
| `MPV-AUD` | mpv `player/audio.c::playing_audio_pts,get_sync_pts,fill_audio_out_buffers`; `filters/f_auto_filters.c::aspeed_process`; `filters/f_autoconvert.c::handle_audio_frame`; `audio/out/buffer.c::ao_read_data,ao_reset,ao_drain,ao_uninit`; `audio/out/ao_coreaudio.c::reset,hotplug_cb` |
| `MPV-SUB` | mpv `sub/dec_sub.c::pts_to_subtitle,sub_read_packets,sub_reset`; `sub/sd_ass.c::decode,get_bitmaps,reset`; `sub/sd_lavc.c::decode,get_bitmaps,reset`; `sub/lavc_conv.c::lavc_conv_decode,lavc_conv_reset`; `sub/osd.c::osd_render`; `sub/osd_libass.c::osd_object_get_bitmaps` |
| `FF-DMX` | FFmpeg `libavformat/demux.c`, `avformat.c`, `seek.c` functions named in [DEPENDENCY_OWNERSHIP.md](DEPENDENCY_OWNERSHIP.md) |
| `FF-DEC` | FFmpeg `libavcodec/avcodec.h`, `decode.c`, `avcodec.c` send/receive/flush/format functions |
| `FF-VT` | FFmpeg `libavcodec/videotoolbox.c`; `libavutil/hwcontext_videotoolbox.c` |
| `FF-SUB` | FFmpeg `libavcodec/{srtdec,ass,pgssubdec,dvdsubdec,dvbsubdec}.c` |
| `ASS` | libass `ass.c`, `ass_render.c`, `ass_shaper.c`, `ass_fontselect.c`, `ass_coretext.c` |
| `PL` | libplacebo `renderer.c`, `colorspace.c`, color/sampling/deinterlace shader APIs |
| `APPLE` | macOS 26.5 SDK `AVSampleBufferRenderSynchronizer.h`, `AVSampleBufferAudioRenderer.h`, queued-sample/video-renderer/display-layer headers |

File licensing and full provenance are in [SOURCE_PINS.md](SOURCE_PINS.md).

## Loading and media discovery

| Behavior | Classification | Concrete current behavior/evidence | Action |
| --- | --- | --- | --- |
| Local file opening | Functionally close | `SP-DMX:init` opens file URLs through FFmpeg and common fixtures load | Retain FFmpeg; move off-main |
| Non-file/remote inputs | Intentionally unsupported | `SP-DMX:init` rejects non-file URLs | Keep a protocol allowlist; evaluate HTTP separately |
| Cancellable open/probe | Missing | `SP-BE:replaceSession` synchronously enters `SP-DMX:init` on `@MainActor`; no AVIO interrupt | Add async `MediaSourceOpener` and cancellation |
| Staged/deeper probing | Missing | one `avformat_find_stream_info`; no partial state or second budget (`SP-DMX`) | Delegate mechanics to `FF-DMX`; own budgets |
| Container/codec parsing breadth | Delegated to a dependency | FFmpeg owns open, demux, parser, codec discovery (`FF-DMX`) | Preserve and pin runtime build evidence |
| Best initial stream | Partial | direct `av_find_best_stream` supplies FFmpeg's generic choice, with no Superplayr language/default/forced policy (`SP-DMX`) | Add product policy over candidates |
| Language preference | Missing | no language ranking beyond FFmpeg generic selection (`SP-DMX`, `MPV-LOAD`) | Deterministic user preference order |
| Default/forced flags | Partial | flags exposed, not fully used for policy (`SP-DMX`, `SP-BE`) | Add selection rules and tests |
| Stable track identity | Partial | IDs are stream index+1, avoiding duplicate demux IDs, but narrowing is unchecked (`SP-BE`) | Stable bounded IDs; no unchecked cast |
| Non-zero start timestamp | Partial | start recorded but never mapped (`SP-DMX`, `SP-SES`) | Timeline origin and end-to-end seek test |
| Negative start timestamp | Missing | no fixture/policy; seek clamps non-negative without mapping (`SP-SES`) | Generate fixture and normalize explicitly |
| Unknown duration | Partial | converted to zero; seeking becomes zero-only (`SP-DMX`, `SP-SES`) | Preserve unknown and capability-gate seek |
| Missing/delayed metadata | Missing | media info is immutable after initial probe (`SP-DMX`) | Track/metadata update events from `FF-DMX` |
| Delayed stream discovery | Missing | no post-open stream enumeration (`SP-DMX`, `FF-DMX`) | Add `TrackCatalog` revisions |
| Unsupported selected codec | Partial | selected video or audio decoder init can fail the whole session (`SP-SES`) | disable failed track or terminal if no A/V |
| No playable A/V | Missing | both decoders may be nil, leaving a subtitle/data-only container loaded with no worker able to complete EOF (`SP-SES`) | reject at load or expose an explicit non-A/V capability |
| File becomes readable with more probe | Missing | no retry policy (`SP-DMX`) | One bounded deeper probe or user retry |
| Partial/truncated file at open | Partial | may open; later error is untyped (`SP-SES`) | Differentiate playable-truncated from clean EOF |
| Reopening/replacing active media | Partial | new session reuses shared sinks before old workers join (`SP-BE`, `SP-SES`) | Global presentation epoch/lease barrier |
| `loaded` versus first-frame state | Partial | loaded and sample-enqueued facts exist; first-frame event means enqueue (`SP-BE`) | Add decoded/enqueued/visible distinctions |
| Audio-only product ingest | Partial | backend/tests can decode, but normal file filtering is video-centric (`SP-PROD`, `SP-TEST`) | Decide product scope, then align file picker |
| Attached picture/cover art | Missing | no one-shot image/track policy (`SP-DMX`, `MPV-DMX`) | Classify, do not treat as normal continuous video |

## Demux, buffering, packets, and time

| Behavior | Classification | Concrete current behavior/evidence | Action |
| --- | --- | --- | --- |
| `AVPacket` ownership | Equivalent | `SP-DMX` moves one ref into `FFmpegPacket`, freed in deinit | Retain |
| FIFO backpressure | Functionally close | `SP-GEN:PacketQueue` blocks producer and wakes on clear/close | Retain under new budget type |
| Count bound | Equivalent | fixed capacities are enforced (`SP-SES`) | Keep as third guard |
| Byte bound | Missing | packet/frame size does not affect capacity (`SP-GEN`) | Add per-queue byte high/low water |
| Buffered-duration bound | Missing | queue does not account media duration (`SP-GEN`) | Add time bound with unknown-time fallback |
| Control priority over full queues | Partial | clear/close wakes blocked pushes, but demux sees seek next loop and check-to-push can admit one stale packet (`SP-SES`, `SP-GEN`) | serialized control channel/actor cancellation and atomic commit |
| Prefetch | Partial | demux fills bounded queues as fast as consumers permit (`SP-SES`) | Make target and hysteresis explicit |
| Multiple buffered ranges | Missing | only current FIFO range (`SP-SES`, `MPV-DMX`) | Defer for local files; preserve interface |
| Seeking within cached data | Missing | all seeks call FFmpeg (`SP-DMX`) | Defer until range cache has product value |
| Demux starvation/`EAGAIN` | Missing | negative read result becomes failure (`SP-DMX`) | Typed `wouldBlock`, buffering state |
| Clean EOF | Partial | exact AVERROR_EOF recognized (`SP-DMX`) | Carry per-stage generation-scoped EOF |
| Stale EOF invalidation on new packet | Missing | EOF remains until seek; no growing-data path (`SP-SES`, `MPV-DMX`) | New packet invalidates matching EOF |
| Demux read failure | Partial | string failure and demux worker exit; other workers may block (`SP-SES`) | Terminal/recoverable state transition |
| Corrupt-packet policy | Missing | no corrupt flag/error budget classification (`SP-DMX`, `FF-DMX`) | Skip/count; sustained threshold |
| Non-monotonic DTS/PTS | Partial | FFmpeg may repair; app has no discontinuity state (`FF-DMX`, `SP-SES`) | Delegate heuristics; own segment/repreroll |
| VFR | Partial | duration fallback uses static FPS/1⁄30; the nominal VFR generator rewrites retained frames to even 12 fps, while the optional long gap fixture lacks semantic assertions (`SP-VID`, `SP-TEST`) | Build a generator self-checking irregular PTS, then exact landing/tail tests |
| Missing packet/frame duration | Partial | video falls back avg FPS/1⁄30; subtitle 5 s (`SP-VID`, `SP-SUB`) | Named inference, no arbitrary universal default |
| Invalid timestamp | Partial | A/V NOPTS becomes invalid `CMTime`/NaN and can bypass the exact-seek floor; only subtitle fallback substitutes zero (`SP-DMX`, `SP-SES`, `SP-SUB`) | Preserve unknown and synthesize only by policy |
| Timestamp arithmetic overflow | Missing | unchecked timestamp×numerator (`SP-DMX`) | checked rational rescale |
| Attached fonts | Functionally close | common attachment types extracted and sent to libass (`SP-DMX`, `SP-SUB`) | Add size/count/lifetime policy |
| Track update/extradata revision | Missing | no `AV_PKT_DATA_NEW_EXTRADATA`/metadata event handling (`FF-DMX`, `SP-DMX`) | `TrackRevision` and decoder reconfigure |

## Video decoding

| Behavior | Classification | Concrete current behavior/evidence | Action |
| --- | --- | --- | --- |
| Codec selection | Delegated to a dependency | FFmpeg default decoder (`SP-VID`, `FF-DEC`) | Keep; expose actual decoder/capability |
| FFmpeg send/receive | Partial | ordinary packet loop retries one send `EAGAIN`, but drain does not resend null after drain `EAGAIN` (`SP-VID`, `SP-AUD`) | implement and contract-test the full send/receive loop |
| Decoder reorder | Delegated to a dependency | best-effort PTS from FFmpeg (`SP-VID`, `FF-DEC`) | Preserve generation and original times |
| Delayed-frame drain | Partial | null-send `EAGAIN` is accepted, receive runs once, and null is not resent before publishing EOF (`SP-VID`, `SP-AUD`) | drain until decoder EOF |
| Hardware config discovery | Partial | device attached and callback prefers VT; no explicit config/profile model (`SP-VID`) | Inspect `AVCodecHWConfig` and actual frame |
| Hardware policy changes | Partial | the command changes only the preference used by the next session; the active decoder is untouched and `compatibility` equals `automatic` (`SP-BE`, `SP-VID`) | Declare next-load-only or perform a typed decoder-revision transaction |
| VideoToolbox actual decode | Delegated to a dependency | FFmpeg/VideoToolbox produce CVPixelBuffer (`FF-VT`, `SP-VID`) | Keep preferred path |
| Hardware-frame lifetime | Equivalent | pixel buffer retained before AVFrame unref (`SP-VID`, `FF-VT`) | Keep, add presentation lease |
| Actual HW status | Partial | configured flag/name can label software as hardware (`SP-VID`, `SP-PROD`) | Report configured vs active vs fallback |
| Initial software fallback | Functionally close | second software context on HW open failure (`SP-VID`) | Add typed reason and profile evidence |
| Runtime VT failure | Partial | any HW-path error causes one software switch/seek (`SP-SES`) | Let VT recreate once; classify corruption |
| Corrupt-frame policy | Missing | corrupt error can trigger HW fallback; software errors only record (`SP-SES`) | Skip/count/keyframe recovery thresholds |
| Midstream codec/extradata recreation | Missing | static decoder context (`SP-SES`, `FF-DMX`) | Track revision drain/recreate |
| Resolution/pixel-format change | Partial | actual frame size exists and per-frame description is made; static viewport/status remain (`SP-VID`, `SP-PRES`) | Atomic output revision and UI update |
| SAR change | Partial | Swift geometry uses static stream SAR; FFmpeg may attach emitted-frame PAR to VT buffers, but no revision is surfaced (`SP-VID`, `FF-VT`) | inspect effective attachments and use actual frame/side-data revision |
| Rotation/display matrix | Partial | static rotation layer transform (`SP-DMX`, `SP-PRES`) | mirror/dynamic/frame metadata tests |
| Color/HDR side data | Partial | common values attached, gaps/ambiguous unspecified remain (`SP-VID`) | P0 propagation/color-patch validation |
| Software decode conversion | Partial | bilinear 8-bit BGRA, no explicit swscale color details (`SP-VID`) | explicit range/matrix, retain precision |
| Predecode frame dropping | Missing | no lateness/seek discard beyond simple exact floors (`SP-SES`, `MPV-VID`) | Add only bounded schedule/seek policy |

## Seeking and EOF

| Behavior | Classification | Concrete current behavior/evidence | Action |
| --- | --- | --- | --- |
| Generation stamping | Functionally close | packets/frames/EOS carry session generation (`SP-GEN`, `SP-SES`) | Extend to epoch+track revision+callbacks |
| Atomic stale rejection at sink | Missing | check-then-enqueue/libass/rate race (`SP-SES`, `SP-BE`) | Serialized commit validates epoch atomically |
| Relative seek | Partial | uses 100 ms sampled position (`SP-BE`) | resolve on authoritative clock snapshot |
| Keyframe seek | Partial | preview is only non-floor path; demux always backward (`SP-DMX`, `SP-SES`) | explicit mode and result |
| Exact seek intent | Partial | public `exact` ignored; non-preview controls behavior (`SP-DMX`, `SP-SES`) | explicit target/tolerance |
| Exact video landing | Partial | first PTS ≥ target, enqueue-level result (`SP-SES`) | actual-frame policy and visibility completion |
| Exact audio landing | Missing | entire crossing frame enqueued (`SP-SES`) | sample trim |
| Preview seek | Partial | latest-wins and video-only readiness exist, but the sample combines synchronizer timing with `DisplayImmediately`, which the Apple header does not recommend (`SP-BE`, `SP-SES`, `SP-PRES`, `APPLE`) | atomic sink commit plus a timestamped or isolated preview route |
| Seek while paused | Partial | rate zero restored; target enqueue not visibility (`SP-SES`) | presented/held target completion |
| Seek during buffering | Missing | no explicit buffering state (`SP-BE`) | cancel starvation generation and repreroll |
| Backend seek after EOF | Partial | `MediaSession` keeps its demux loop and can reset generation/EOF, but does not reset old PTS-derived buffer metrics (`SP-SES`) | invalidate every EOF/metric stage under the new generation |
| Product seek after EOF | Missing | product EOF clears the event identity and marks stopped/idle; later backend seek events are rejected, while Play reloads the item (`SP-PROD`, `SP-BE`) | choose one explicit ended/keep-open/unload contract and route seek/play consistently |
| Rapid repeated seek | Functionally close | one pending newest request (`SP-GEN`) | exact/stop priority and near-EOF outcome guard |
| Seek near/past EOF | Partial | active stream with no qualifying frame can leave preroll active (`SP-SES`) | EOS satisfies terminal preroll with clamped result |
| Demux/decoder/queue flush | Partial | generation, queue clear, and FFmpeg/presenter flush exist, but sink commits race and resampler/libass state is incomplete (`SP-SES`) | completion barriers and resampler/libass reset |
| Subtitle seek reset | Missing | visual/cache clear only, events remain (`SP-SUB`) | flush/rebuild active events around target |
| Seek completion event | Missing | no requested/actual landing record (`SP-BE`) | typed result with actual A/V times |
| Seek failure transition | Missing | demux seek failure sets a string but leaves the seek phase active; preview dispatch can remain blocked (`SP-SES`, `SP-GEN`, `SP-BE`) | terminal/recoverable seek result must close the operation exactly once |
| Seek metric generation reset | Missing | seek leaves old `videoPTS`, `audioPTS`, and buffered-duration values; a backward seek can report phantom buffer against the new clock (`SP-SES`) | generation-tag or reset submit horizons atomically with seek |
| Stale EOF rejection | Partial | item generation checked, but `markEnded` transition can race (`SP-SES`) | check inside one atomic state transition |
| Decoder EOF | Partial | drain can publish queue EOS after null-send `EAGAIN` without resending null to decoder EOF (`SP-VID`, `SP-AUD`) | exact FFmpeg contract and resampler tail |
| Renderer drain | Missing | queue EOS pauses synchronizer immediately (`SP-SES`, `SP-PRES`) | wait final presentation end/renderer evidence |
| Global/product EOF | Partial | emitted from early `metrics.ended` (`SP-BE`, `SP-PROD`) | barrier over required presented EOF states |
| Looping | Missing | playlist advancement exists, but no production repeat/loop mode exists (`SP-PROD`) | omit explicitly or add only after presented EOF as a new generation |

## Audio, clock, and output

| Behavior | Classification | Concrete current behavior/evidence | Action |
| --- | --- | --- | --- |
| Audio codec decode | Delegated to a dependency | FFmpeg decoder (`SP-AUD`, `FF-DEC`) | Keep |
| Basic stereo resample/downmix | Functionally close | Float32 48 kHz stereo with swresample (`SP-AUD`) | Validate channel contribution/clipping |
| Resampler input format change | Missing | constructed once from first frame (`SP-AUD`) | drain/rebuild revision |
| Resampler delay/tail | Missing | not included/drained (`SP-AUD`) | exact sample timeline and EOF drain |
| Shared A/V timebase | Delegated to a dependency | one Apple synchronizer/audio renderer clock (`SP-PRES`, `APPLE`) | Keep as routine master |
| Video-only host clock | Partial | Apple uses the host clock when no audio renderer is attached, but `NativePresentationCoordinator` always attaches one (`SP-PRES`, `APPLE`) | Attach only active renderers; verify clock and sufficient-media behavior |
| Audio-only renderer/readiness | Partial | an empty video renderer is always attached and `rendererReady` always requires video readiness (`SP-PRES`, `SP-SES`) | Attach/check only active renderers; validate audio-only start and EOF |
| A/V drift measurement | Partial | difference between last submitted audio/video start PTS, not an audible/display delta (`SP-SES`, `SP-TEST`) | separate sample-end submit, renderer, and physical metrics |
| Playback start threshold | Partial | one accepted sample/frame; Apple sufficient-data deferral (`SP-SES`, `SP-PRES`) | explicit time threshold bounded by EOF |
| Buffering determination | Partial | `minPositive` drops a zero A/V horizon and can hide one starved stream; queue-empty starvation can also ignore Apple-held media (`SP-SES`, `SP-BE`) | model each active queue/renderer horizon and reason explicitly |
| Audio underrun | Missing | no typed renderer/starvation recovery (`SP-SES`) | hold clock, refill, resume |
| Video starvation | Missing | no explicit policy (`SP-SES`) | bounded hold/drop/buffering state |
| Frame drop/repeat | Delegated to a dependency | routine Apple scheduling; app counter never changes (`SP-PRES`, `SP-TEST`) | instrument; add app policy only on evidence |
| Pause/resume clock | Partial | synchronizer rate is set 0/1, but callback/device serialization is absent and sleep/wake has two resume authorities (`SP-PRES`, `SP-PROD`, `SP-BE`) | one session authority; serialize seek/preroll/rate and callbacks |
| Playback speed | Intentionally unsupported | capability false/no-op (`SP-BE`) | add after core via Apple time pitch if justified |
| Pitch correction/time stretch | Intentionally unsupported | absent (`SP-BE`, `MPV-AUD`) | optional later; no mpv code adaptation |
| Audio delay | Intentionally unsupported | capability false (`SP-BE`) | future timestamp mapping, not sleep |
| Output-device selection | Intentionally unsupported | capability false (`SP-BE`) | reconsider with explicit multichannel scope |
| Device hotplug/auto-flush | Missing | audio renderer notifications not observed (`SP-PRES`, `APPLE`) | observe, serialize, recreate/reprime |
| Sleep/wake recovery ownership | Partial | controller and backend both remember resume intent and issue resume actions; controller `play()` can bypass the backend's exact wake-seek preroll (`SP-PROD`, `SP-BE`) | route one lifecycle command through the session state machine |
| Audio renderer error | Missing | only video status sampled (`SP-SES`, `SP-PRES`) | typed output fault path |
| Native multichannel PCM | Missing | always stereo (`SP-AUD`) | medium priority after correct stereo |
| Audio passthrough | Intentionally unsupported | no bitstream path (`SP-AUD`) | keep omitted |
| Audio shutdown/drain | Partial | queue/worker stop exists; played-tail proof absent (`SP-SES`) | presented EOF and device callback quiescence |

## Subtitles

| Behavior | Classification | Concrete current behavior/evidence | Action |
| --- | --- | --- | --- |
| Embedded ASS/SSA ingest | Functionally close | codec private/chunks to libass (`SP-SUB`, `ASS`) | add epoch-atomic commit/reset |
| ASS shaping/layout | Delegated to a dependency | libass/HarfBuzz/FriBidi/CoreText (`ASS`) | do not reimplement |
| Animated/karaoke ASS | Requires real-media validation | libass supports it; 100 ms backend timer limits cadence (`SP-SUB`, `SP-BE`, `ASS`) | display-link/time-aware redraw and hashes |
| Embedded SRT/simple text | Partial | raw UTF-8 wrapper into ASS (`SP-SUB`) | delegate conversion to `FF-SUB` |
| WebVTT/mov_text/other text | Partial | narrow codec-name heuristic (`SP-SUB`) | FFmpeg subtitle decoder/converter |
| External ASS | Partial | `ass_read_memory` works, but shared-track replacement can mix continuing embedded packets into the external track (`SP-SES`, `SP-SUB`, `SP-BE`) | prepare/commit a distinct subtitle source revision |
| External SRT | Partial | custom UTF-8 block parser (`SP-SUB`) | FFmpeg demux/decode, broad encoding policy |
| External SSA/WebVTT intake | Missing | product file allowlist accepts only `.ass` and `.srt`, so these formats cannot reach the backend through normal UI ingest (`SP-PROD`, `SP-SUB`) | expand the allowlist only with FFmpeg-backed decoding and capability tests |
| External load without select | Partial | can replace active libass track (`SP-BE`) | prepare-only source; commit on selection |
| Multiple external tracks | Missing | one shared libass track (`SP-BE`) | catalog sources; one primary initially |
| Subtitle enable/source synchronization | Missing | embedded worker, external track replacement, and `isEnabled` access share no atomic revision boundary; `eventCount` metrics read is also unlocked (`SP-SES`, `SP-SUB`, `SP-BE`) | serialize enable/source/metrics under subtitle revision ownership |
| Font attachments | Functionally close | extracted, copied into libass (`SP-DMX`, `SP-SUB`, `ASS`) | size/count/session lifetime limits |
| Font fallback | Delegated to a dependency | libass CoreText/default fallback (`ASS`) | install log callback/diagnostics |
| Subtitle track switch | Partial | whole session replacement; state ambiguities (`SP-BE`) | subtitle-only revision and rollback |
| Subtitle off | Partial | nil can mean auto/default in session selection (`SP-BE`, `SP-SES`) | tri-state automatic/disabled/stream |
| Subtitle delay | Partial | positive delay queries future cue, opposite mpv semantics (`SP-SUB`, `MPV-SUB`) | define positive=later and subtract |
| Secondary subtitles | Intentionally unsupported | none (`SP-BE`, `MPV-SUB`) | defer until user value established |
| Seek clearing/rebuild | Missing | overlay caches cleared, libass events persist (`SP-SUB`) | generation reset and cue preroll |
| EOF clearing | Partial | timer/cue duration dependent (`SP-SUB`, `SP-SES`) | explicit final/loop/unload transition |
| PGS | Missing | selected compressed packet sent to libass; no output (`SP-SUB`, `FF-SUB`) | FFmpeg decode + region compositor |
| VobSub/DVD subtitle | Missing | same (`SP-SUB`, `FF-SUB`) | FFmpeg decode + region compositor |
| DVB bitmap subtitle | Missing | same (`SP-SUB`, `FF-SUB`) | FFmpeg decode + region compositor or scope gate |
| Bitmap-region composition | Missing | AppKit path accepts libass masks only (`SP-SUB`) | common timed region model |
| Rotation/resize viewport | Requires physical-device validation | static geometry and AppKit overlay; some synthetic tests (`SP-SUB`, `SP-PRES`, `SP-TEST`) | all rotations/display/continuous resize |
| HDR subtitle brightness | Missing | separate SDR AppKit overlay (`SP-SUB`, `ASS`, `PL`) | explicit reference white/blend policy |
| Subtitle in PiP | Intentionally unsupported | main overlay only (`SP-BE`) | document; revisit with unified compositor |

## Track changes and lifecycle

| Behavior | Classification | Concrete current behavior/evidence | Action |
| --- | --- | --- | --- |
| Audio track discovery | Functionally close | streams exposed with metadata/dispositions (`SP-DMX`, `SP-BE`) | dynamic updates and policy |
| Disable audio | Partial | nil resolves back to FFmpeg best stream (`SP-SES`, `SP-BE`) | tri-state selection |
| Audio track switching | Partial | full session rebuild at sampled time (`SP-BE`) | prepare audio decoder, commit revision, repreroll |
| Audio switch rollback | Missing | old session stopped before replacement proven (`SP-BE`) | two-phase prepare/commit |
| Audio preroll after switch | Partial | ordinary whole-session seek/preroll (`SP-BE`, `SP-SES`) | video-anchor sample trim |
| Subtitle clearing on switch | Partial | clears display but worker/source mixing can continue (`SP-BE`, `SP-SUB`) | atomic source revision |
| External track callback invalidation | Partial | outer events gated, shared libass mutation can race (`SP-BE`, `SP-SUB`) | epoch at commit |
| Duplicate/malformed native IDs | Partial | indices provide uniqueness, but unchecked `Int64`-to-`Int32` narrowing can trap (`SP-BE`) | reject out-of-range values safely |
| Stop | Partial | closes queues/advances generation, stops presenter (`SP-SES`) | atomic lease revoke and final state |
| Unload | Partial | backend clears media and presentation (`SP-BE`) | make state-machine terminal and waitable |
| Close during load | Missing | synchronous uncancellable open (`SP-BE`) | interruptable async open |
| Close during seek/decode | Partial | generation/queue close and wait group (`SP-SES`) | callback/sink commit barrier |
| Waitable teardown | Partial | a worker group is waitable, but backend shutdown still publishes completion after its timeout (`SP-SES`, `SP-BE`) | timeout is a typed failure, not completion |
| Callback invalidation | Partial | outer product gate plus non-atomic internal checks (`SP-PROD`, `SP-SES`) | global epoch in every completion |
| Worker teardown after terminal failure | Missing | `failRenderer` records a string; demux failure can return while other workers remain blocked and the product failure path does not stop the backend (`SP-SES`, `SP-BE`, `SP-PROD`) | terminal transition revokes sinks, closes queues, cancels IO, and joins workers |
| Legacy libmpv/OpenGL removal | Missing | package still links CMpv/OpenGL and defaults legacy (`Package.swift`, `SP-PROD`) | removal milestone after native acceptance |

## Picture quality and validation

| Behavior | Classification | Concrete current behavior/evidence | Action |
| --- | --- | --- | --- |
| Native-size SDR VT | Requires physical-device validation | direct CVPixelBuffer Apple path (`SP-VID`, `SP-PRES`) | tagged color patches vs mpv/QuickTime |
| Upscaling | Requires physical-device validation | Apple opaque scaler (`SP-PRES`, `PL`) | common 720/1080→4K visual/objective gate |
| Downscaling | Requires physical-device validation | Apple opaque scaler (`SP-PRES`, `PL`) | 4K→window/1080p gate |
| Chroma reconstruction | Partial | FFmpeg attaches chroma location on VT buffers; software parity and effective Apple use are unverified (`SP-VID`, `FF-VT`, `PL`) | inspect attachments and run boundary fixtures |
| Limited/full range | Partial | VT fourcc reliance; software swscale not explicit (`SP-VID`) | P0 numeric/color-patch tests |
| BT.601/709/2020 | Partial | common attachments; software conversion risk (`SP-VID`) | explicit swscale and tagged controls |
| PQ/HDR10 | Requires physical-device validation | PQ/BT.2020/HDR metadata partially attached (`SP-VID`, `SP-PRES`) | EDR/SDR/external display matrix |
| HLG | Requires physical-device validation | HLG transfer attached (`SP-VID`) | same matrix |
| EDR presentation | Requires physical-device validation | screen headroom observed, layer outcome not proven (`SP-BE`, `SP-PRES`) | record headroom/layer/display evidence |
| HDR→SDR | Requires physical-device validation | delegated opaquely to Apple (`SP-PRES`, `PL`) | acceptance threshold before Metal |
| Tone/gamut mapping controls | Intentionally unsupported | no controls (`SP-PRES`) | keep deferred |
| Dithering | Intentionally unsupported | no explicit stage (`SP-PRES`, `PL`) | add only if gradients fail |
| Debanding | Intentionally unsupported | absent (`SP-PRES`, `PL`) | optional later |
| Deinterlacing | Missing | no field policy (`SP-VID`, `PL`) | detect/test, focused stage or unsupported |
| Pixel aspect output | Partial | FFmpeg attaches frame PAR on VT, but Swift display geometry stays static and software/sample-description parity is unverified (`SP-VID`, `SP-PRES`, `FF-VT`) | inspect/fix/test anamorphic samples |
| Screenshot | Intentionally unsupported | capability false (`SP-BE`) | later color-consistent capture path |
| Software 10-bit/HDR quality | Partial | 8-bit BGRA conversion (`SP-VID`) | retain high precision or explicit limitation |

## Diagnostics and test evidence

| Behavior | Classification | Concrete current behavior/evidence | Action |
| --- | --- | --- | --- |
| Structured session/seek IDs | Partial | outer load identity and inner wrapping generation exist but reset/advance independently and are not one commit authority (`SP-GEN`, `SP-PROD`) | unify epoch/revision journal |
| First-frame metric | Partial | means video enqueue, audio-only never reports (`SP-BE`) | decoded/enqueued/visible milestones |
| Hardware decoder metric | Partial | typed booleans lost; software name can become hardware (`SP-BE`, `SP-PROD`) | preserve typed path state |
| Dropped-frame metric | Missing | counter exists but is never incremented (`SP-SES`, `SP-TEST`) | Apple performance metrics/app decisions |
| A/V difference metric | Partial | last-submitted start-PTS difference only (`SP-SES`, `SP-TEST`) | label correctly; add renderer/physical evidence |
| Buffered ranges | Missing | a start-PTS-minus-clock proxy, with no sample-end or renderer occupancy (`SP-BE`) | queue/renderer ranges and starvation reason |
| Error diagnostics | Partial | bounded strings, few typed payloads (`SP-BE`, `SP-SES`) | structured fault records |
| Synthetic fixture breadth | Partial | broad common codecs, nonzero, HDR, tracks, and subtitles exist, but the nominal VFR fixture is actually even-rate and optional fixtures can silently skip (`SP-TEST`) | self-check every generated property, then add semantic edge fixtures |
| Native semantic assertions | Partial | no renderer-drain EOF, exact landing, negative start, race barriers (`SP-TEST`) | implement differential/fault harness |
| Long-run memory | Requires real-media validation | prior 30 min POC runs passed; latest HEAD not fully rerun (`SP-TEST`) | repeat after state refactor |
| Sleep/wake, displays, devices | Requires physical-device validation | manual report lists them outstanding (`SP-TEST`) | mandatory release matrix |

## Baseline highest-priority gaps

1. Global epoch-checked sink commit and waitable replacement.
2. Cancellable off-main open/read.
3. Timeline normalization preserving unknown/negative/non-zero time.
4. Explicit seek/preroll/drain/EOF state machine with audio trim.
5. Typed terminal/recovery transitions.
6. Correct decoder/resampler drain and dynamic format revisions.
7. Subtitle decoder routing and seek/track isolation.
8. Color/SAR/range correctness and physical HDR/device validation.
9. Measured diagnostics replacing enqueue-level proxies.
10. Removal of legacy libmpv/OpenGL surfaces after native acceptance gates pass.

These priorities lead directly to [RECOMMENDED_REFACTOR.md](RECOMMENDED_REFACTOR.md).

## Current highest-priority follow-on

1. Establish the immutable oracle/fixture manifest and capture a pinned mpv
   smoke artifact before broadening comparisons.
2. Implement semantic load/track/timeline and exact/keyframe/preview/EOF
   comparisons on existing verified fixtures.
3. Add self-checking VFR, negative/unknown time, corrupt/truncated, delayed-tail,
   and format-change fixtures; never infer coverage from filenames.
4. Reuse the production-driver fault seams for differential policy scenarios;
   compare live mpv only where a live process can express the same behavior.
5. Calibrate presentation/color/audio tolerances and finish the physical
   display/device matrix before using it as a release claim.

The detailed sequence and CI split are in
[TEST_FIXTURE_PLAN.md](TEST_FIXTURE_PLAN.md).
