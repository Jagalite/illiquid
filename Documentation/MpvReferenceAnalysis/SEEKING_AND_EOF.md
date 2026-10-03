# Seeking, EOF, and lifecycle

## Verdict

Seek and EOF are the highest-risk correctness areas. Superplayr has useful
generation and coalescing primitives, but its current seek modes are not
faithfully implemented, its generation checks race shared sinks, and its EOF is
presentation-submission completion rather than presentation completion. These
require one session state machine before further feature work.

## Seek-mode comparison

| Requested behavior | mpv | Baseline Superplayr (`fbdc699`) | Required native policy |
| --- | --- | --- | --- |
| Relative seek | Resolves against current position, combines queued relatives | Backend resolves against a timer-sampled `currentTime` | Resolve in session actor against authoritative clock snapshot |
| Keyframe/imprecise seek | Low-level seek, no decode-to-exact target | Preview is the only path that omits exact floors | Explicit `.keyframe` mode with completion at first valid post-seek frame |
| Exact seek | Seeks behind target, decodes forward, skips video, clips audio | Demux `exact` parameter is ignored; non-preview always applies floors | Explicit `.exact` target/tolerance with video discard and sample-level audio trim |
| Preview/scrub seek | Delayed/coalesced seek can wait for a visible frame | Latest preview target coalesces; displayed image retained | Separate preview intent, paused result, aggressive coalescing, no audio enqueue |
| Seek while paused | Restart state can become ready without advancing normal playback | flushes and sets requested resume rate, usually zero | Preserve pause/rate intent; complete only after target image is presented/held |
| Seek during buffering | Resets state and cache logic | no explicit buffering state | Cancel buffering generation; prioritize control; enter seek preroll |
| Seek after EOF | Resets EOF and restarts pipelines | generation resets local EOF; renderer was already paused early | Invalidate all stage EOF latches and renderer drain state |
| Rapid repeated seek | precision-aware coalescing; waits briefly for visible feedback | one pending newest target, regardless of intent priority | Coalesce preview, but never let preview override exact/stop; bounded feedback cadence |

Sources: `mpv:player/core.h::seek_params`; `mpv:player/playloop.c::mp_seek,
queue_seek,execute_queued_seek`; `Superplayr:Playback/SeekCoordinator.swift`;
`Media/FFmpegDemuxer.swift::seek`; `Media/MediaSession.swift::seek @` their pinned
SHAs.

## mpv's exact-seek mechanics

mpv distinguishes the desired player target from the lower-level demux target.
For high-resolution seeks it usually moves the demux target backward by at least
a small preroll, flushes playback state, asks the decoder to drop aggressively
before the target, and retains the last decoded video frame if the requested
time is beyond available media. Video accepts the first frame within a small
tolerance. Audio waits for the selected video landing and clips the decoded PCM
frame to the exact boundary.

The unusual repeated-seek guard is historical, not incidental. Commit
`57fbc9cd76f7a78f1034c42dd3c453ff35123264` fixed issue #7206: a pending exact
seek used to reset the player before EOF became conclusive, leaving the last
frame displayed instead of advancing the playlist. Current `execute_queued_seek`
waits for the full A/V high-resolution result near EOF.

Sources: `mpv:player/playloop.c::mp_seek,execute_queued_seek`;
`mpv:player/video.c::video_output_image`;
`mpv:player/audio.c::ao_process`; `mpv:audio/aframe.c::
mp_aframe_clip_timestamps @
94335ab87ab225ca3e36e0faeac831639d3e1d4e` (LGPL-2.1-or-later); [mpv issue
#7206](https://github.com/mpv-player/mpv/issues/7206).

## Baseline Superplayr seek transaction (`fbdc699`)

Baseline `MediaSession.seek`:

1. clamps target to `0...duration`;
2. advances a session-local generation;
3. records exact floors for any non-preview seek;
4. clears packet/frame queues and subtitle display caches;
5. flushes the shared presentation coordinator at the target;
6. queues the latest seek request;
7. demux thread calls `avformat_seek_file(..., AVSEEK_FLAG_BACKWARD)` and
   `avformat_flush`;
8. decode workers lazily flush on observing the new generation;
9. presentation workers discard stale generations and pre-target frames;
10. playback resumes after one accepted frame from each active A/V stream.

Strengths:

- generation advances before most invalidating work;
- packet, decoded frame, flush, and EOS items carry a generation;
- newest pending seek coalesces;
- stale EOS is checked at queue boundaries, although the final EOF commit still
  has a check-then-lock race;
- software fallback uses the same invalidation path.

Concrete defects:

- `FFmpegDemuxer.seek(to:exact:)` ignores `exact` and always performs a backward
  demux seek;
- `MediaSession` chooses floor behavior from `isPreview`, not `exact`, making the
  public exact boolean effectively dead;
- unknown duration became zero, so clamp forces the target to zero;
- non-zero/negative stream origin is not mapped to player time;
- video landing is the first enqueued qualifying frame, not a displayed frame;
- audio accepts and enqueues the whole PCM frame whose end crosses the target,
  so audio can begin before an exact target;
- invalid/missing A/V PTS becomes invalid `CMTime` and is not governed by a
  synthesis/error policy; subtitle packets alone fall back to zero when both
  PTS and DTS are absent;
- EOS cannot satisfy preroll, so seeking near EOF can remain prerolling if a
  required stream yields no qualifying frame;
- subtitles are visually cleared but existing libass events are not flushed;
- an internal `onSeekCompleted` callback exists, but the backend uses it only
  for preview coalescing; no product event carries requested and actual landing
  times;
- a demux seek failure records a string but leaves `SeekCoordinator` in its
  active phase, which can keep preview coalescing blocked indefinitely.
- seek resets generation and EOF/preroll fields but leaves the old generation's
  `videoPTS`, `audioPTS`, and buffered-duration metrics. After a backward seek,
  snapshot can compare those stale submit horizons with the new clock and
  temporarily hide buffering.

Sources: `Superplayr:Media/FFmpegDemuxer.swift::seek`;
`Media/MediaSession.swift::seek,demuxLoop,videoPresentationLoop,
audioPresentationLoop,startIfPrerolled`;
`Playback/SeekCoordinator.swift::takePending,markPrerolling @
fbdc699627bebf4298a630004ca31a31b0ec5df4`.

Classification: **partial**, with correctness failures for exact audio, unknown
duration, timeline origin, and near-EOF completion.

Seek-after-EOF is also inconsistent across layers. `MediaSession` remains alive
and can accept a new seek generation, but product EOF deactivates the current
event identity and marks playback stopped/idle. A later seek can reach the
backend while its identity-tagged events are rejected; Play instead reloads the
playlist item. The refactor must choose and test one contract: keep an `ended`
session addressable for seek/replay, or unload it and require an explicit
reload. It must not expose both behaviors accidentally.

Additional source: `Superplayr:SuperplayrPlayer/Player/
PlaybackController.swift::play,handle(.endOfFile) @` the Superplayr baseline
SHA.

## The generation race

An `accepts(generation)` check is not atomic with mutation of Apple/libass state.
An old frame can pass the final check; another thread advances generation and
flushes; then the old frame enqueues after the flush. File replacement is worse:
generations restart inside each `MediaSession`, while old and new sessions share
one `NativePresentationCoordinator` and `SubtitlePipeline`. The old session is
stopped but not awaited before the new session starts, allowing stale enqueue,
subtitle event insertion, clock-rate changes, or a late hardware-recovery seek
to affect the new file.

Sources: `Superplayr:Media/MediaSession.swift::videoPresentationLoop,
audioPresentationLoop,subtitleLoop,startIfPrerolled,
recoverVideoDecoderFromHardwareFailure`;
`Production/NativeAppleBackend.swift::replaceSession @` the Superplayr baseline
SHA.

More pre-enqueue checks cannot close a check-then-act race. Required solution:
all sink mutations pass through one presentation/subtitle executor whose commit
operation validates a global `PlaybackEpoch` and `OperationGeneration` while
serialized. Alternatively, each media session owns distinct sinks and the old
session is fully quiesced before the surface swaps. A global epoch-checked lease
is the recommended balance.

## Required seek state machine

```text
idle/playing/paused/ended
        |
        v
requested --(coalesce compatible intent)--> requested
        |
        v
invalidating
  - snapshot paused/rate/track intent
  - advance operation generation
  - cancel blocking demux/read work
  - revoke presentation lease
        |
        v
flushing
  - stop rate
  - serialize Apple flush completion
  - clear app queues
  - flush demux/parsers and active decoders
  - reset resampler and subtitle events
        |
        v
demuxSeeking -> decodingPreroll -> presentationPreroll
        |                |                 |
        +------ failure -+-----------------+--> failed or recovered
                                             |
                                             v
                                   readyPaused / playing / ended
```

Completion rules:

- `.keyframe`: first valid video frame at/after the decoder's returned boundary;
  audio starts at the corresponding mapped time.
- `.exact`: video PTS is target or the closest available frame under a declared
  tolerance; PCM before target is trimmed; if target is past stream end, last
  frame/EOF resolves the request rather than hanging.
- `.preview`: video-only, latest target wins, paused display; no audio/subtitle
  state is allowed to overwrite a later exact seek.
- Seek completion is an event containing generation, requested target, actual
  video/audio start, whether landing was exact/clamped/EOF, and presentation
  readiness. Enqueue alone is not “presented”.

Current preview samples set `kCMSampleAttachmentKey_DisplayImmediately` while
the display layer is controlled by `AVSampleBufferRenderSynchronizer`. The
macOS 26.5 SDK header explicitly says that combination is not recommended.
Preview should either perform a paused, timestamped synchronizer transaction or
use an isolated preview surface; choose between them with physical latency and
stale-frame tests, not by retaining the current attachment as an implicit rule.

Evidence: `Superplayr:Media/MediaSession.swift::videoPresentationLoop` and
`Presentation/SampleBufferVideoPresenter.swift::enqueue`; macOS 26.5 SDK
`AVFoundation/AVSampleBufferDisplayLayer.h` (Apple proprietary platform API,
inspected 2026-07-19).

## EOF is a pipeline, not a bit

Required per-track progression:

```text
reading -> demuxEOF -> decoderDraining -> decodedEOF
        -> presenterDraining -> presentedEOF
```

Global EOF is true only when every required active track is `presentedEOF` (or
is explicitly disabled) and no newer generation exists. Seeking or receiving a
new packet invalidates every EOF latch for that generation.

### mpv behavior

mpv sends a decoder drain, consumes delayed frames, lets video reach a draining
state while the VO still displays queued frames, and normally lets audio reach
EOF only after the AO has played queued samples. Gapless mode can mark the
current file's audio logically complete while a persistent AO continues into
the next file. The playloop declares ordinary EOF after active audio and video
are both complete, with guards for disabled chains and paused final frames.
Playlist advance, loop, and keep-open are player policies applied after that
fact.

Sources: `mpv:video/decode/vd_lavc.c::decode_frame`;
`mpv:filters/f_decoder_wrapper.c::lavc_process`;
`mpv:player/audio.c::fill_audio_out_buffers`;
`mpv:player/video.c::write_video`; `mpv:player/playloop.c::handle_eof,
handle_loop_file,handle_keep_open @` the pinned mpv SHA (LGPL-2.1-or-later).

### Baseline Superplayr behavior (`fbdc699`)

The demux loop publishes EOS to selected queues. Decoders send nil and publish a
decoded-frame EOS after their receive loop. Presentation loops enqueue available
frames and immediately mark a stream ended when they consume that EOS marker.
When all active streams are marked ended, `MediaSession` pauses the synchronizer.
There is no proof that Apple played the queued tail. The last audio/video can
therefore be truncated, and backend EOF/playlist advancement can happen early.

Audio also does not drain the `SwrContext` tail. Both decoders accept a null-send
`EAGAIN`, receive available frames once, and publish queue EOS without resending
null until decoder EOF, so delayed frames can be lost. No current integration
test asserts media-tail presentation time.

Sources: `Superplayr:Media/{MediaSession,VideoDecoder,AudioDecoder}.swift`;
`Production/NativeAppleBackend.swift::tick @` the Superplayr baseline SHA.

Classification: decoder draining is **partial**; playback EOF is **missing**.

## Loop, stop, unload, and replacement

- Production currently has playlist advancement but no repeat/loop mode. If
  looping is later added, it must be a new seek generation after
  `presentedEOF`, not a special stale-EOS bypass. Acceptance would require no
  gap beyond a declared threshold, no old tail after the new origin, and
  correct subtitle/audio reset.
- Seeking backward after EOF follows the ordinary seek transaction and
  invalidates all EOF/drain latches.
- Stop means revoke the lease, cancel work, flush outputs, and publish stopped;
  unload additionally destroys media/track state.
- Replacing a file must not share mutable sinks until old callbacks are
  impossible or rejected atomically by a higher global epoch.
- Close during open/seek/decode/presentation must converge on one waitable
  `closed` state. A timeout is an internal fault, not permission to reuse an
  object that may still callback.
- Teardown first revokes commits, cancels IO, and closes/wakes queues; it then
  joins workers before destroying any worker-referenced decoder, demux, or sink
  context. A deadline failure remains a terminal teardown fault.

## Regression tests derived from invariants

1. Exact seek into the middle of an audio frame: assert no sample before target
   and A/V starts within tolerance.
2. Rapid exact seeks through and beyond EOF: exactly one final outcome and no
   suppressed playlist advance.
3. Seek after EOF, then play: enforce the selected product keep-open or reload
   contract; old EOF never wins and the tail plays once.
4. Seek in VFR: actual landing is a real frame PTS, not average-FPS synthesis.
5. Seek damaged/non-monotonic media: bounded recovery, no infinite preroll.
6. Preview storm followed by exact seek: exact intent wins and its generation is
   the only one committed.
7. Pause-seek: target image becomes visible while clock remains stopped.
8. Replace file while an old frame is paused immediately before sink commit:
   deterministic barrier proves the old frame cannot enqueue or change rate.
9. Replace during hardware fallback: old recovery cannot flush the new file.
10. Long ASS cue across seek: correct cue appears once; no old/duplicate event.
11. Audio/video with delayed decoder frames: final sample/frame is presented
    before EOF event.
12. Audio-only and video-only EOF: each resolves without waiting on a nonexistent
    renderer.
13. Unknown-duration seek capability: disabled or bounded by known seek window,
    never clamped silently to zero.
14. Close at every state-machine edge with injected blocked read: waitable,
    callback-safe teardown.
15. Backward seek before the first new sample: buffered-duration and submit-PTS
    metrics are unknown/zero for the new generation, never inherited from the
    old future horizon.

The differential form of these tests is specified in
[TEST_FIXTURE_PLAN.md](TEST_FIXTURE_PLAN.md).
