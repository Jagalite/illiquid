# Audio and synchronization

## Verdict

Use `AVSampleBufferRenderSynchronizer` as the routine macOS clock/presentation
authority. Do not reproduce mpv's manual AO/VO drift controller on top of it.
Superplayr must nevertheless own timeline mapping, exact audio trim, preroll and
underrun state, renderer/device notifications, format revision, and the boundary
between decoder drain and samples actually played.

## mpv's synchronization model

mpv treats audio output time as master in ordinary A/V playback. The AO reports
queued/device delay; the player subtracts that delay from the written audio PTS
to estimate the audible clock. Video computes the next-frame duration from PTS,
measures its timing against audio, smooths the error, and schedules or drops
late frames. Large/non-positive timestamp differences become discontinuities
rather than normal frame durations. Systematic repetition, frame mixing, and
audio resampling/tempo correction belong principally to mpv's display-sync
modes, not ordinary audio-master playback.

Source: `mpv:player/audio.c::playing_audio_pts`; `mpv:player/video.c::
adjust_sync,handle_new_frame,check_framedrop,write_video @
94335ab87ab225ca3e36e0faeac831639d3e1d4e` (LGPL-2.1-or-later).

At restart, mpv waits until required audio and video reach readiness. Exact
audio start can wait for the actual video landing and clip PCM. Audio underrun
does not immediately free-run video: the player can enter buffering, refill a
threshold, and restart. At EOF, audio remains draining until the AO reports its
queued samples played in normal mode. Gapless playback is the explicit
exception: the file can reach logical audio EOF while a persistent AO continues
asynchronously into the next file.

Sources: `mpv:player/playloop.c::handle_playback_restart,handle_update_cache`;
`mpv:player/audio.c::get_sync_pts,audio_start_ao,fill_audio_out_buffers @` the
pinned mpv SHA (LGPL-2.1-or-later).

Alternative mpv sync modes can use display timing, drop/repeat, resample audio,
or frame mixing. They are part of mpv's multi-output renderer design and are not
automatically relevant to an Apple synchronizer.

## Apple sample-buffer model

`AVSampleBufferRenderSynchronizer` synchronizes multiple queued-sample renderers
to one timebase. With an audio renderer attached, the default source clock is
the audio renderer's clock; without one, the host clock is used. Rate/time
changes are timebase operations. `delaysRateChangeUntilHasSufficientMediaData`
can defer advancement until every attached renderer reports enough data.

The audio renderer exposes output-device selection and time-pitch algorithm.
Device/route/rate changes can automatically flush it and can stop the
synchronizer or change its timebase. Apple's automatic-flush notification can
arrive on an arbitrary thread; flush and enqueue must be serialized, followed
by refill/repreroll.

Evidence: macOS 26.5 SDK headers
`AVFoundation/AVSampleBufferRenderSynchronizer.h` and
`AVFoundation/AVSampleBufferAudioRenderer.h` (proprietary Apple platform APIs,
inspected 2026-07-19).

Consequences:

- Apple owns fine-grained device-clock synchronization and renderer queueing.
- Superplayr owns which timestamps are submitted, when a coherent generation is
  ready, and what to do on auto-flush/device failure.
- Polling two “last enqueued PTS” values is not A/V drift measurement at the
  speakers/display.
- An enqueue success is not playback completion.

## Baseline Superplayr audio path (`fbdc699`)

FFmpeg decodes the chosen stream. The C shim creates one `SwrContext` on the
first frame and converts all audio to packed interleaved Float32, 48 kHz, stereo
using a default output channel layout. It sets a rematrix maximum but does not
define product channel-mapping policy. It is never rebuilt if input sample
format, rate, or layout changes, and its delay/tail is not drained at EOF.

`SampleBufferAudioPresenter` copies the PCM `Data` into a new CoreMedia block
buffer and enqueues timed audio. `NativePresentationCoordinator` attaches audio
and video renderers to one synchronizer unconditionally and enables delayed
rate change. That includes video-only sessions, so the documented Apple
host-clock behavior for a synchronizer without an audio renderer is not the
current video-only behavior. An empty attached renderer can also participate in
the sufficient-media gate. The coordinator has no audio-renderer automatic-
flush observer, output-device policy, or typed renderer recreation path.

Sources: `Superplayr:CFFmpeg/include/ffmpeg_shim.h::
superplayr_create_audio_resampler,superplayr_audio_resampler_output_capacity,
superplayr_convert_audio_frame,superplayr_reset_audio_resampler`;
`Media/AudioDecoder.swift`; `Presentation/SampleBufferAudioPresenter.swift`;
`Presentation/NativePresentationCoordinator.swift @
fbdc699627bebf4298a630004ca31a31b0ec5df4`.

Classification: common stereo decode is **functionally close**; dynamic format,
tail drain, exact landing, multichannel, device changes, and recovery are
**missing or partial**.

## Timestamp and exact-seek gaps

Audio PTS uses FFmpeg best-effort timestamp without compensating for
`swr_get_delay`, synthesizing missing PTS, or tracking exact converted sample
origin. A seek accepts a PCM frame if its end reaches the target but enqueues
the entire frame. That violates sample-accurate landing and can make audio start
early. At EOF, decoder output drains but `SwrContext` tail does not.

Sources: `Superplayr:Media/AudioDecoder.swift::decode,drain,convert`;
`Media/MediaSession.swift::audioPresentationLoop @` the Superplayr baseline SHA.

Required model for each audio block:

```text
source PTS + source sample count
    -> resampler input origin/delay
    -> exact output start + output sample count
    -> optional leading/trailing trim
    -> CMSampleBuffer presentation interval
```

Every arithmetic conversion should use checked rational rescaling. Missing PTS
must produce a named synthesized-time diagnostic or a track failure; it must not
become zero silently.

## Playback start, pause, starvation, and video starvation

Current preroll means one submitted sample/frame from each active stream. Apple
may defer rate until it has sufficient data, but Superplayr does not expose the
reason or a declared start threshold. The presentation loops poll readiness in
2 ms sleeps rather than using request-media callbacks. Backend buffered duration
is approximated from each stream's last submitted **start PTS** minus
synchronizer time, not an explicit state or a true buffered end. Backend buffering uses
`minPositive(videoAhead, audioAhead)`, which discards a zero horizon; one
starved active stream can therefore be masked by the other stream's positive
horizon. Conversely, the starvation counter sees empty app queues even when an
Apple renderer may still hold healthy media.

The renderer set is not symmetric today. `NativePresentationCoordinator`
always attaches both renderers. Video-only therefore does not get Apple's
documented no-audio host-clock configuration, while audio-only keeps an empty
video renderer in the sufficient-media decision. `MediaSession.snapshot` also
computes `rendererReady` from video readiness unconditionally, so a healthy
audio-only session can never report renderer-ready.

Required policy:

- preroll target is a small time window per active renderer, bounded by EOF;
- paused seek needs only the target video image, while audio remains primed but
  clock-stopped;
- audio underrun stops/holds the coordinated clock, refills to a resume
  threshold, then restarts at the same mapped time;
- video starvation may hold/repeat the last image while audio continues only
  under a bounded lateness policy; sustained starvation enters buffering;
- isolated late video frames may be dropped before enqueue; reference packets
  are never discarded arbitrarily at the demux queue;
- pause snapshots the synchronizer time/rate atomically; resume reuses the same
  timebase unless a renderer flush requires repreroll.
- construct or reconfigure the synchronizer with only the active renderer set;
  video-only uses the host clock and audio failure degradation removes the
  failed audio renderer before repreroll; audio-only never waits on an empty
  video renderer or video readiness.

Sleep/wake currently has two playback authorities. `PlaybackController` records
resume intent, forwards sleep/wake, and calls `play()` after wake;
`NativeAppleBackend` independently records intent and queues an exact wake seek
with its own resume rate. The controller's immediate `play()` can therefore set
rate before that seek has landed and reprerolled. The session must become the
single owner of lifecycle recovery: the product layer sends one lifecycle
event, and rate resumes only after the wake seek, flush, and active-renderer
preroll commit.

Sources: `Superplayr:Player/PlaybackController.swift::systemWillSleep,
systemDidWake`; `Production/NativeAppleBackend.swift::systemWillSleep,
systemDidWake`; `Presentation/NativePresentationCoordinator.swift::init`;
`Media/MediaSession.swift::snapshot @` the Superplayr baseline SHA.

Routine frame repetition is an Apple presentation detail. Superplayr should add
manual frame-drop/repeat logic only when real metrics show Apple's route cannot
meet A/V thresholds.

## Playback speed and pitch

mpv can insert `scaletempo2` (WSOLA), resample for speed/drift, or allow pitch
change. Its output chain detects format/rate/channel changes and drains/rebuilds
the resampler. Superplayr currently capability-gates playback speed as
unsupported.

Sources: `mpv:player/audio.c::recreate_audio_filters`;
`mpv:filters/f_auto_filters.c::aspeed_process` for automatic tempo/drop
selection; `mpv:filters/f_autoconvert.c::handle_audio_frame,
autoconvert_command` for final format/resampler negotiation;
`mpv:audio/filter/af_scaletempo2_internals.c @` the pinned mpv SHA. The latter
source documents a Chromium-derived WSOLA implementation; it must not be copied.

Recommendation after the core refactor:

1. test `AVSampleBufferAudioRenderer` time-pitch algorithms at 0.5–2.0x;
2. if quality/capability is acceptable, use Apple and keep timestamps/rate in
   one synchronizer;
3. otherwise add a separately licensed, focused time-stretch stage;
4. never adapt mpv's algorithm without a separate provenance/license review.

## Audio delay

Audio delay is currently unsupported. Implement it as timeline mapping, not an
arbitrary sleep: shift audio presentation timestamps relative to the common
media timeline, repreroll on changes, and include the delay in seek clipping and
EOF calculation. Bound UI values and expose actual applied delay.

## Output device, failure, and hotplug

mpv's ordinary CoreAudio output registers device/hotplug listeners, reselects
the device, refreshes latency, emits a hotplug event, and serializes
reset/start/stop. It does not itself request an AO reload for every hotplug;
the exclusive CoreAudio output requests reload when its stream format changes.
It deliberately delays stopping the AudioUnit: immediate stop made wireless
pause/seek restart visibly slow, while reset alone left `coreaudiod` consuming
CPU and preventing sleep. Commit `ab419a6660c6f8f78b30ba0838ab3c274746af89`
resolved that tradeoff after issue #11617.

Sources: `mpv:audio/out/ao.c::ao_request_reload,ao_hotplug_event`;
`mpv:audio/out/ao_coreaudio.c::reset,stop_after_idle_time,hotplug_cb`;
`mpv:audio/out/ao_coreaudio_exclusive.c::property_listener_cb @` the pinned mpv
SHA (LGPL-2.1-or-later); [issue #11617](https://github.com/mpv-player/mpv/issues/11617).

Superplayr uses a different Apple API, so it should not copy this workaround.
It should test equivalent product outcomes:

- observe automatic flush and renderer failure;
- serialize notification handling with enqueue;
- pause the synchronizer, recreate/reselect device if needed, and reprime audio
  at current media time;
- if audio cannot recover but video can, switch explicitly to video-only host
  clock with a user-visible audio error;
- ensure paused playback releases power assertions/CPU after an acceptable
  grace interval;
- validate built-in, USB/HDMI, Bluetooth/AirPlay-like, disconnect/reconnect, and
  sleep/wake on physical hardware.

## Stereo, multichannel, and passthrough

The current fixed stereo downmix is safe as an initial baseline and diagnostics
already retain source layout. It is not equivalent to mpv's negotiated channel
maps or native multichannel PCM. Product-value order:

1. correct stereo downmix with center/LFE/surround fixtures and no clipping;
2. preserve source channel labels and support multichannel decoded PCM when the
   selected Apple device advertises it;
3. device-specific downmix/upmix policy;
4. bitstream passthrough remains intentionally unsupported.

Passthrough increases device-format, seeking, rate, volume, and synchronization
complexity and is not essential to Superplayr's macOS target. Document it as a
capability reason, not a generic playback failure.

## Required invariants and acceptance metrics

1. The common media timeline is monotonic within a generation; discontinuities
   create a revision or recovery transition.
2. Audio block timestamps include resampler delay and exact sample count.
3. Resampler is drained at EOF and rebuilt on input/output format revision.
4. Exact seek trims leading PCM to target; no early sample is enqueued.
5. Apple auto-flush/device callbacks are epoch-tagged and serialized with
   enqueue/flush.
6. A/V “drift” uses renderer/timebase evidence, not the difference between last
   submitted sample start PTS values. A future submit horizon must include each
   sample's duration and remain a separate backpressure metric.
7. EOF waits for the last audible sample and displayed frame.
8. Renderer/device recovery has a bounded retry budget and an explicit degraded
   video-only outcome.
9. Stop/replacement guarantees no old audio, rate change, or callback after the
   new presentation lease begins.
10. Physical qualification must record device, route, OS build, sample rate,
    channels, time-pitch mode, underruns, max A/V difference, power assertion,
    and memory.
11. One session authority owns pause/resume intent and sleep/wake recovery;
    rate cannot resume until the recovery operation has committed.
12. Sufficient-media, readiness, starvation, and EOF consider only renderers
    for active tracks; audio-only and video-only are first-class configurations.
