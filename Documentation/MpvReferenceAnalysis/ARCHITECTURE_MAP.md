# Architecture map

Baseline: Superplayr `fbdc699627bebf4298a630004ca31a31b0ec5df4`, inspected
2026-07-19. The topology and weakness sections below are historical findings at
that revision. At `6825c6b` on 2026-07-20, Superplayr completed the deterministic
core authority, production driver, final native fences/leases, reactive
projection, and native-only runtime described by the implemented contract in
[FCIS_COMPLETION_MATRIX.md](../FCIS_COMPLETION_MATRIX.md).

## One-sentence comparison

mpv is an explicit player-core state machine coordinating independently
buffered demux, filters, decoders, outputs, clocks, and subtitles; at the
`fbdc699` baseline, Superplayr was a set of worker queues coordinated by shared
locks around an Apple synchronizer, with good local ownership primitives but
insufficiently explicit cross-subsystem state.

## mpv's control topology

```text
client/input/commands
        |
        v
 MPContext + playloop  <----> playlist/load lifecycle
   |       |      |
   |       |      +---- subtitle decoder/OSD (libass or FFmpeg bitmap decode)
   |       +----------- audio chain -> AO/device clock
   +------------------- video chain -> VO/GPU/libplacebo
        |
        +---- demux reader/cache -> selected stream packet queues
                 |
                 +---- low-level demuxer (often FFmpeg/libavformat)
```

`MPContext` is the coordination authority. The playloop polls progress rather
than allowing a worker callback to mutate arbitrary player state. Audio, video,
and subtitles expose status and demand; the player decides when a seek,
restart, EOF transition, or teardown is complete.

Sources: `mpv:DOCS/tech-overview.txt`; `mpv:player/core.h::MPContext,
playback_status`; `mpv:player/playloop.c::run_playloop @
94335ab87ab225ca3e36e0faeac831639d3e1d4e` (mostly LGPL-2.1-or-later; the
technical overview is documentation).

## mpv playback state

The central per-output progression is:

```text
SYNCING -> READY -> PLAYING -> DRAINING -> EOF
```

- `SYNCING`: decoder/filter/output is being aligned after load or seek.
- `READY`: the output has a valid starting point but global A/V restart may
  still be waiting on the other required output.
- `PLAYING`: global restart completed; clocks advance.
- `DRAINING`: no more decoded input, but the output still owns playable data.
- `EOF`: the output is complete for player policy. Normal audio reaches it only
  after AO playback drains; gapless mode is an explicit exception in which the
  current file can reach audio EOF while the persistent AO continues
  asynchronously into the next file.

Global EOF requires both active audio and active video to report EOF, with a
special guard for a paused last video frame. An absent chain is treated as EOF
for restart coordination, but `handle_eof` deliberately refuses a normal global
EOF if both A/V chains were disabled at runtime. This separation is why mpv does
not equate decoder EOF with playback EOF.

Sources: `mpv:player/core.h::enum playback_status`; `mpv:player/playloop.c::handle_eof`;
`mpv:player/audio.c::fill_audio_out_buffers`; `mpv:player/video.c::write_video`
at the pinned mpv SHA (LGPL-2.1-or-later).

## mpv seek state and invariants

mpv represents a seek as target type, amount, precision, and flags. Relative
seeks can be combined; an absolute seek replaces earlier intent; requested
precision is not silently weakened. Delayed interactive seeks wait briefly for
a visible frame so holding a seek key does not leave a frozen UI. An A/V
high-resolution seek near EOF is allowed to resolve EOF before the next queued
seek resets state.

Core invariants:

1. Compute the logical target separately from the lower-level demux seek point.
2. For exact seeking, seek behind the target, decode forward, and discard until
   the target tolerance is met.
3. Flush every decoder/filter/output state that can retain pre-seek data.
4. Audio landing waits for the chosen video-frame timestamp and clips PCM at the
   boundary; it does not enqueue the whole crossing frame.
5. A new seek resets EOF; a later packet also invalidates stale demux EOF.
6. Repeated seek intent is coalesced without erasing a conclusive EOF outcome.
7. A cached seek is allowed only when the relevant selected streams have a
   compatible range and keyframe/refresh point.

Sources: `mpv:player/core.h::seek_params`; `mpv:player/playloop.c::mp_seek,
queue_seek,execute_queued_seek`; `mpv:player/video.c::video_output_image`;
`mpv:player/audio.c::ao_process`; `mpv:audio/aframe.c::
mp_aframe_clip_timestamps`; `mpv:demux/demux.c::queue_seek,
find_seek_target,add_packet_locked` at the pinned mpv SHA (LGPL-2.1-or-later).

## mpv demux queue model

mpv has a producer-side demux context and a locked reader view. The cache owns
packets until pruning or range destruction releases them; a reader receives a
new reference/copy. It maintains
per-stream queues and multiple LRU ranges, and reports a range only where the
eager selected streams overlap. Sparse/lazy subtitles do not incorrectly cap
the A/V range. Queue policy has:

- forward and backward byte budgets;
- minimum time/readahead targets;
- byte/time hysteresis for chunked prefetch;
- selected versus eager/lazy streams;
- keyframe-indexed reader heads;
- range-join validation using position and timestamps;
- a disk-cache option;
- explicit underrun and seeking state;
- one-shot attached-picture handling;
- stale EOF clearing when new data arrives for ordinary streams; caption
  pseudo-streams can set `ignore_eof` to avoid repeated EOF churn.

When the byte limit is reached while a decoder still demands data, mpv logs a
queue overflow and can publish EOF to an empty requesting stream instead of
growing without bound. That is a degradation policy, not a lossless guarantee.

Sources: `mpv:demux/demux.c::demux_internal,demux_queue,demux_cached_range,
add_packet_locked,read_packet,update_seek_ranges,demux_get_reader_state`;
`mpv:DOCS/tech-overview.txt`
at the pinned mpv SHA (LGPL-2.1-or-later).

## mpv decoder and output ownership

- The demux cache retains its packet until pruning or range destruction.
  Advancing a reader head does not transfer that cached object;
  `read_packet_from_cache` returns a new packet reference/copy owned by the
  decoder-side consumer.
- FFmpeg's send/receive API owns internal references after a successful send;
  mpv must drain receive on `EAGAIN` and at EOF.
- The decoder wrapper corrects/records PTS, detects static versus dynamic
  format changes, manages segment drains, and exposes a frame to the output
  chain.
- Hardware frames keep their device/frame context alive. The VO or conversion
  chain holds a frame reference until presentation no longer needs it.
- `f_autoconvert` drains an old converter before installing a new one when
  format changes permit it; audio format change can pause the chain while the
  player reopens the AO.
- VO/AO reconfiguration is an output concern, not something FFmpeg completes.

Sources: `mpv:filters/f_decoder_wrapper.c::feed_packet,process_output_frame`;
`mpv:filters/f_autoconvert.c::handle_video_frame,handle_audio_frame`;
`mpv:filters/f_output_chain.c::user_wrapper_process,check_in_format_change`;
`mpv:video/decode/vd_lavc.c::send_packet,receive_frame` at the pinned mpv SHA
(LGPL-2.1-or-later for headed files; consult mpv `Copyright` for unheaded filter
sources).

The output chain distinguishes optional user processing from mandatory format
conversion. A failed user filter can be bypassed; a mandatory conversion
failure is fatal and synthesizes EOF so downstream code cannot wait forever.
The video output queue retains frames until the VO thread consumes them,
invalidates old frame IDs on seek reset, has a first-frame wait barrier, and
joins its thread in destroy. The audio buffer avoids calling the device callback
under its main lock and provides explicit reset/start/drain/uninit ordering.

Sources: `mpv:filters/f_output_chain.c::user_wrapper_process,
check_in_format_change`; `mpv:video/out/vo.c::vo_queue_frame,vo_seek_reset,
vo_wait_frame,vo_destroy`; `mpv:audio/out/buffer.c::ao_read_data,ao_reset,
ao_start,ao_drain,ao_uninit @` the pinned mpv SHA (LGPL-2.1-or-later for the
headed files).

mpv's macOS AVFoundation audio output is not analogous to Superplayr's shared
A/V synchronizer. `ao_avfoundation` owns an audio-only synchronizer and a large
device buffer; its restart notification path warns that restarting can
desynchronize. It is an output workaround catalog, not a shared-clock design to
adopt.

Source: `mpv:audio/out/ao_avfoundation.m::feed,start,stop,init` and
`AVObserver::handleRestartNotification @` the pinned mpv SHA
(LGPL-2.1-or-later).

## mpv command and client boundaries

`command.c` validates/routs commands into player operations: load replaces or
appends playlist entries, track-add opens an external source, and track
properties call the track-switch machinery rather than mutating decoder state
directly. `client.c` is an event-delivery boundary. Each client has a bounded
1000-event queue, reserves space for pending asynchronous replies, chokes new
events after overflow, and requires waiters/callback work to stop before client
destruction and global shutdown.

Sources: `mpv:player/command.c::run_command,cmd_loadfile,cmd_track_add,
mp_property_switch_track`; `mpv:player/client.c::send_event,mpv_wait_event,
mp_destroy_client,mp_shutdown_clients @` the pinned mpv SHA (`command.c`
LGPL-2.1-or-later; `client.c` ISC-style).

## mpv load and teardown ordering

Open can run asynchronously under an abort token. `cancel_open` cancels and
joins the opener without a timeout. A different path,
`kill_demuxers_reentrant`, applies `demux_termination_timeout` to already-open
demuxers and can force termination. Per-file teardown does not always destroy
outputs: the VO is normally persistent, and the AO may persist for gapless
playback. The material safety constraints are:

1. stop client-visible playback progress;
2. invalidate callbacks and uninitialize the file's audio/video/subtitle chains;
3. detach stream selection and destroy track state;
4. cancel/join outstanding open work and terminate active demux work safely;
5. destroy demuxers and cached packet state after consumers are detached;
6. publish the final stop/end reason after stale callbacks can no longer win.

`loadfile.c` contains assertions that output/decoder state is gone before the
demuxer is freed. Client commands and events are separated from internal object
lifetime; `player/client.c` adds API coordination, not playback semantics.

Sources: `mpv:player/loadfile.c::open_demux_thread,cancel_open,
kill_demuxers_reentrant,uninit_demuxer,play_current_file`; `mpv:player/client.c`
at the pinned mpv SHA
(LGPL-2.1-or-later except `player/client.c`, ISC-style).

## Baseline Superplayr topology

```text
NativeAppleBackend (@MainActor)
    |
    +-- MediaSession
    |    +-- FFmpegDemuxer (one AVFormatContext)
    |    +-- video/audio/subtitle packet queues
    |    +-- video/audio decoded-frame queues
    |    +-- demux, decode, and presentation DispatchQueues
    |    +-- PlaybackGeneration + SeekCoordinator
    |
    +-- NativePresentationCoordinator
    |    +-- AVSampleBufferRenderSynchronizer
    |    +-- AVSampleBufferVideoRenderer
    |    +-- AVSampleBufferAudioRenderer
    |
    +-- SubtitlePipeline
         +-- LibassContext
         +-- AppKit overlay
```

The local ownership primitives are sound:

- `FFmpegPacket` moves and frees one `AVPacket`;
- codec contexts and reusable frames are decoder-confined;
- a VideoToolbox `CVPixelBuffer` is retained past the source `AVFrame`;
- queues close and broadcast to wake blocked waiters;
- a waitable worker group exists;
- seek generations reject many stale packets and frames.

Sources: `Superplayr:Sources/SuperplayrNativePlaybackPOC/Media/{FFmpegPacket,
MediaSession,VideoDecoder,AudioDecoder}.swift`; `Playback/{PacketQueue,
PlaybackGeneration,SeekCoordinator}.swift @
fbdc699627bebf4298a630004ca31a31b0ec5df4`.

## Baseline cross-subsystem weaknesses

The generation is local to each `MediaSession`, while presentation and subtitle
objects are shared across replacement sessions. Checking a generation and then
enqueuing is not one serialized commit. Therefore an old worker can pass its
check, a seek/replacement can flush, and the old worker can enqueue afterward.
The same race exists between subtitle validation and `ass_process_chunk`.

Other architectural mismatches:

- load/probe/decoder construction occurs synchronously on `@MainActor`;
- queue clear/close wakes blocked producers, but demux observes seek at its next
  loop and generation-check-to-push is not atomic;
- queue capacity is item count, regardless of a packet's bytes or duration;
- static stream metadata configures geometry/audio conversion even after emitted
  frame parameters change;
- renderer failure is recorded but not mapped to a state transition;
- one submitted sample per active stream is considered preroll;
- EOS at the decoded-frame queue pauses the synchronizer immediately;
- first-frame readiness means video enqueue, not display;
- track switches reconstruct the whole media session instead of revising one
  track pipeline.

Sources: `Superplayr:Media/MediaSession.swift::seek,demuxLoop,
videoPresentationLoop,audioPresentationLoop,markEnded,startIfPrerolled`;
`Production/NativeAppleBackend.swift::replaceSession,tick` at the Superplayr
baseline SHA.

## Architectural translation and implemented form

Superplayr should copy none of mpv's objects or control flow. The baseline
translation proposed the following behavioral shape for Swift/macOS:

- one session actor as the only authority for lifecycle state;
- one cancellable media-source opener and one serialized FFmpeg demux owner;
- per-track decode actors with explicit flush/drain/reconfigure contracts;
- a timeline mapper between media time and non-negative presentation time;
- a presentation session owning Apple renderers behind an epoch-checked lease;
- a recovery supervisor with typed faults and bounded budgets;
- dependency adapters that expose capabilities, not dependency-specific product
  commands.

The implementation preserved these ownership goals but did not require a
literal actor or separately acknowledged effect for every low-level phase.
`SuperplayrPlaybackCore` is the deterministic authority,
`PlaybackRuntimeDriver` is the sole serialized product command/result path, and
the native runtime may aggregate tightly coupled work when the acknowledgement
states what it proves and preserves effect identity, failure, cancellation, and
fault injection. The implemented contract is
[FCIS_COMPLETION_MATRIX.md](../FCIS_COMPLETION_MATRIX.md); the original target
design remains in [RECOMMENDED_REFACTOR.md](RECOMMENDED_REFACTOR.md).
