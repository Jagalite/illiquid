# Error handling and recovery

## Verdict

Recovery must be typed, generation-scoped, and bounded. At the `fbdc699`
baseline, Superplayr mostly stored a failure string while workers continued, or
treated any hardware decode error as a VideoToolbox failure. The refactor needs
a `RecoverySupervisor`
that decides one of: retry, recreate a subsystem, fall back to software, skip an
item, disable a track, stop with a user-visible error, or mark a capability
unsupported.

## Fault model

Every fault record should contain:

```text
timestamp
playbackEpoch / operationGeneration / trackRevision
stage: open | probe | demux | decode | convert | subtitle | present | output | teardown
domain: FFmpeg | VideoToolbox | AVFoundation | CoreMedia | libass | IO | internal
numeric code + stable symbolic name
classification: temporary | corruptInput | unsupported | resource | platform | internal
scope: packet | frame | track | presenter | session
consecutiveCount / totalCount / retryBudgetRemaining
actionTaken / resultingState
media PTS/DTS, stream ID, codec, format, device, queue depths
userMessageKey
```

String logs remain useful detail, but they cannot drive recovery or capability
state.

## Source behavior catalog and native policy

| Condition | Dependency/mpv behavior | Baseline Superplayr (`fbdc699`) | Recommended policy |
| --- | --- | --- | --- |
| Local open failure | FFmpeg returns a concrete AVERROR; mpv fails load | throws from synchronous init | **Stop with user-visible error**; distinguish missing/permission/invalid/unsupported; allow explicit retry |
| Probe incomplete but bytes remain | FFmpeg has bounded probe/analyze and `EAGAIN`; mpv has growing pre-probe/user knobs | fixed one-shot stream info | **Retry once** under a larger documented budget only when essential parameters remain incomplete |
| Unsupported codec/no decoder | mpv disables failed track; file fails only if no useful A/V | selected decoder failure aborts load | **Disable track** if another required medium remains; otherwise **stop unsupported** |
| No selected/playable A/V | mpv load policy requires a useful playable outcome or exits | session can be constructed with both A/V decoders nil and never reach EOF | **Reject load or enter an explicit still-image/subtitle-only capability**, never report ordinary playing |
| Demux `EAGAIN`/temporary starvation | FFmpeg propagates; mpv waits/retries | treated as fatal read result | **Retry/wait** under cancellation and starvation state |
| Demux read error | mpv warns and performs bounded read retries, then exhausts; can look EOF-like | sets failure and exits demux worker | **Bounded retry**, drain valid queued data, end as `truncated/readFailure`, never clean EOF |
| Clean EOF then new packet | mpv packet arrival clears ordinary stream/global EOF; caption pseudo-streams can ignore EOF churn | static local EOF sleeps until seek | **Invalidate stale EOF** for matching generation; growing mode remains separately gated |
| Isolated corrupt packet | FFmpeg marks/logs; decoder may reject; mpv skips decode output | a decode or frame-conversion throw while hardware is configured may trigger SW fallback; Apple enqueue errors instead call `failRenderer` | **Skip packet/frame**, increment rate-limited counter; do not conflate input corruption, conversion, and presenter faults |
| Sustained corrupt frames/no progress | mpv logs/skips ordinary software decode errors without an analogous consecutive terminal threshold; its default count of three is specifically hardware-fallback policy | software errors record failure but loop continues | **Keyframe recovery once**, then **disable track/stop** after a Superplayr-owned time-and-count budget |
| VideoToolbox init unavailable | FFmpeg candidate/init fails; mpv tries next/software | software retry on `avcodec_open2` failure | **Software fallback immediately**; capability reason includes codec/profile/resource |
| VT invalid session/malfunction | FFmpeg invalidates and can recreate the session without a documented one-attempt bound; mpv counts repeat errors and falls back | any thrown HW error switches to software | Let FFmpeg's internal recreation run, but give Superplayr **one observed recreation budget**; repeat → **recreate software decoder** under new generation |
| VT reference-missing/no frame | FFmpeg can tolerate callback without resetting | not classified | **Skip/count**, wait for safe keyframe; do not condemn VT on one reference error |
| Hardware frame incompatible with presenter/conversion | mpv requests fallback and hard-resets video chain | conversion error triggers SW path but can race sink | **Reconfigure presenter** if format supported; otherwise **software fallback** once |
| Midstream resolution/pixel/color change | decoder emits new properties; mpv drains/reconfigures VO | per-frame description but static geometry/policy | **Recreate affected presentation revision** atomically |
| Audio input format/layout/rate change | mpv blocks chain, drains converter, reopens AO as needed | one resampler forever | **Drain/rebuild resampler and format description**, repreroll shared timebase |
| Audio decode error | mpv skips isolated errors; disables audio if chain fails | failure metric, worker may continue/block | **Skip/count**; sustained failure → **disable audio** if video remains, else stop |
| Audio output/device failure or auto-flush | mpv coordinates AO policy; ordinary CoreAudio reselects/refreshes and emits hotplug, while exclusive-format change can request reload; Apple exposes device/flush notifications | not observed | **Recreate audio renderer/device once**, reprime A/V; then video-only or terminal by policy |
| Video renderer requires flush/fails | Apple exposes flush-needed/failure state; mpv VO failure disables video | video failure is checked after enqueue and in snapshots, but `requiresFlushToResumeDecoding` is not handled; audio has no corresponding status/error path | **Flush/reprime once**, then **recreate renderer**, then terminal video failure |
| Renderer starvation | mpv enters underrun/cache pause; Apple can delay rate | software queue heuristics only | **Enter buffering**, stop/hold timebase, refill declared threshold, resume |
| Subtitle parser error | mpv/libass/FFmpeg drop malformed cue | mostly silent | **Skip cue**; sustained init/parser failure → **disable subtitle only** |
| Missing font/glyph | libass uses CoreText/default fallback and logs | fallback exists, no callback diagnostics | **Continue**, log missing family/glyph and selected fallback |
| Bitmap subtitle while unsupported | mpv routes to FFmpeg bitmap decoder | track can be selected but renders nothing | **Mark track unsupported**; do not advertise it as playable until compositor exists |
| Queue high-water reached | mpv stops prefetch; hard overflow can force stream EOF | producer blocks by count | **Backpressure**; queue-budget violation is internal fault, never clean EOF |
| Timestamp discontinuity | FFmpeg repairs some; mpv warns/resets around large jumps | mostly passes timestamps through | **Start new timeline segment/repreroll** when outside tolerance; skip irreparable packet |
| Unexpected/truncated EOF | mpv can ultimately expose EOF after read retries | concrete non-EOF read errors become a generic failure, while truncation that FFmpeg reports as EOF is marked as clean completion | **Drain queued valid data**, publish failure-ended outcome when evidence exists, and retain an explicit limitation when the demuxer cannot distinguish truncation from EOF |
| Repeated init failure | mpv exhausts finite decoder/output candidates | repeated session rebuild possible | **Circuit-break capability** for file+track+device+revision; require state change/user retry |
| Teardown timeout | mpv's open-thread `cancel_open` joins without a deadline; `kill_demuxers_reentrant` alone can force already-open demux termination after its configured timeout | Superplayr emits shutdown completion after 3 s even on timeout | **Report teardown failure**; revoke callbacks/resources; never claim clean completion or reuse |

Key sources at pinned revisions:

- `FFmpeg:libavformat/demux.c::ff_read_packet,read_frame_internal`;
- `FFmpeg:libavcodec/decode.c::decode_receive_frame_internal`;
- `FFmpeg:libavcodec/videotoolbox.c::videotoolbox_decoder_callback`;
- `mpv:demux/demux_lavf.c::demux_lavf_read_packet`;
- `mpv:demux/demux.c::add_packet_locked,read_packet`;
- `mpv:video/decode/vd_lavc.c::handle_err,receive_frame`;
- `mpv:player/audio.c::fill_audio_out_buffers`;
- `mpv:audio/out/ao.c::ao_request_reload`;
- `mpv:sub/sd_ass.c::decode`; `mpv:sub/sd_lavc.c::decode`;
- `libass:libass/ass.c::ass_process_chunk`;
- `Superplayr:Media/MediaSession.swift::demuxLoop,videoDecodeLoop,
  audioDecodeLoop,failRenderer,recoverVideoDecoderFromHardwareFailure`;
- `Superplayr:Production/NativeAppleBackend.swift::tick,shutdown`.

Full SHAs and licenses: [SOURCE_PINS.md](SOURCE_PINS.md).

## Recovery state machine

```text
healthy
  | fault
  v
classifying
  |-- isolated input damage --> skipping --> healthy
  |-- temporary starvation --> waiting/refilling --> healthy
  |-- recoverable subsystem --> invalidating --> recreating --> prerolling --> healthy
  |-- optional track terminal --> disablingTrack --> degraded
  |-- required path terminal --> failingSession --> closed
  `-- unsupported capability --> unsupported (no retry loop)
```

All recovery transitions go through the session actor. A decoder or renderer
worker reports evidence; it never independently calls a shared seek/flush. This
removes the current race where an old session's late hardware error can flush a
new session.

## Retry budgets

Recommended initial defaults are policies to test, not copied mpv constants:

| Fault | Budget |
| --- | --- |
| Local `EAGAIN`/temporary no-data | wait while cancellable; bounded wall-clock progress timeout |
| Deeper probe | one escalation, with exact byte/time budget logged |
| Consecutive corrupt video/audio frames | tolerate a small count and a short media-time window; reset on sustained successful output |
| VT session recreation | one per track revision |
| VT-to-software replacement | one per playback epoch |
| Apple video renderer flush/reprime | one, followed by one renderer recreation |
| Apple audio renderer/device recreation | one per device revision |
| Keyframe recovery after sustained corruption | one per discontinuity region |
| Subtitle malformed events | rate-limited; disable only after repeated failures preventing useful output |
| Teardown deadline | one deadline; no continued background reuse after expiry |

Exact numeric thresholds should be tuned through the corrupt/truncated/failure-
injection fixtures. Every successful frame or stable interval must define which
consecutive counter resets; otherwise a long file with sparse errors eventually
fails incorrectly.

## Partial playback versus terminal failure

| Remaining media | Failed component | Outcome |
| --- | --- | --- |
| playable video + failed audio | audio track/output | continue video-only only after visible warning and clock transition |
| playable audio + failed video | video decoder/presenter | continue audio-only if product UI supports it; otherwise stop visibly |
| A/V playable + subtitle failure | subtitle | subtitles off; playback continues |
| no playable A/V | any primary failure | terminal session error |
| requested optional track fails during switch | new track | rollback to old track where possible; otherwise disable requested track |
| source becomes unreadable after buffered data | demux IO | play already accepted data, then end as read failure, not completion |

“Disable track” must update the track catalog/capabilities and satisfy EOF/preroll
barriers. A dead track cannot remain logically required.

## Baseline failure-lifecycle defect (`fbdc699`)

Several worker failures call `failRenderer`, which only sets
`metrics.rendererFailure`. A demux failure then returns without clearing
`running` or closing queues, so decoder, presenter, and subtitle workers can
remain blocked in `BoundedQueue.pop`. The backend's next `tick` emits a failure,
but the product coordinator's failed-event handler does not necessarily stop
the backend. This can leave audio, workers, or polling alive behind a failed UI
state.

Audio output failure is a separate blind spot: `SampleBufferAudioPresenter`
exposes readiness and enqueue but no surfaced status/error, and the wait-until-
ready loop has no failure or timeout exit. A failed audio renderer can therefore
look like permanent backpressure instead of a typed output fault.

Track-switch preparation is also destructive today. `replaceSession` stops the
old playable session before the replacement decoder/session is proven; if
construction fails, the backend cannot roll back to the old track.

Sources: `Superplayr:Media/MediaSession.swift::demuxLoop,failRenderer,
waitUntilReady`; `Presentation/SampleBufferAudioPresenter.swift`;
`Production/NativeAppleBackend.swift::replaceSession,tick`;
`SuperplayrPlayer/Player/PlaybackController.swift` failed-event handling at the
Superplayr baseline SHA.

Required invariant:

> A terminal session fault atomically revokes presentation, closes data queues,
> cancels IO, transitions the product once, and begins waitable teardown. No
> worker can remain operational solely because it did not observe a string.

## Failure-injection tests

Use narrow adapters around FFmpeg/Apple/libass calls so tests can deterministically:

1. block and cancel open/read;
2. return `EAGAIN`, clean EOF, and concrete IO failures in sequence;
3. corrupt one packet versus a sustained run;
4. make VT initialization fail;
5. make VT fail before first frame and after successful frames;
6. make VT session recreate succeed/fail;
7. emit a midstream video/audio format revision;
8. trigger Apple automatic audio flush/device change;
9. set video renderer `requiresFlushToResumeDecoding`/failure;
10. fail subtitle parsing and font lookup;
11. stall a queue at its high-water mark while issuing seek/stop;
12. delay an old callback until after file replacement;
13. time out teardown and prove the new session cannot reuse its resources.

Each test asserts state transitions, action count, retry exhaustion, user outcome,
no false EOF, no stale sink mutation, and no live workers after close.

## Unsupported is not failure

The capability model must distinguish:

- unsupported by product scope (passthrough, optical navigation, scripts);
- unsupported by current implementation (bitmap subtitles before milestone);
- unsupported by source/codec/profile;
- unavailable on this Mac/device/display;
- transiently unavailable (VT resource, disconnected output);
- failed despite being declared supported (bug/recovery path).

That distinction prevents pointless retries and makes user-visible errors
actionable.
