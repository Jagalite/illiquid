# Superplayr architecture

Superplayr uses a deterministic functional playback core with an imperative,
reactive application shell.
There is one production engine: the native FFmpeg/VideoToolbox/sample-buffer
runtime.

## Ownership

| Layer | Owns | Must not own |
| --- | --- | --- |
| `SuperplayrPlaybackCore` | deterministic state, command/result reduction, effect identity, generation and seek barriers, drain/EOF, recovery budgets, sync/buffering/lifecycle, track intent, subtitle revision and delay state | framework objects, queues, clocks, UI observation |
| `SuperplayrNativePlayback` | exact native-operation ledger, active/candidate media sessions, FFmpeg input and decoding, VideoToolbox, bounded queues, renderer demand, AVSampleBuffer presentation, isolated subtitle pipelines, resource leases, PiP transitions and platform callbacks | product preferences, playlist policy, UI state |
| `SuperplayrPlayer` | product command routing, session identity gate, persistence checkpoints, native runtime lifetime, owned folder-discovery tasks, immutable view-snapshot publication | decoder or renderer policy, backend selection |
| `SuperplayrApp` | the single player-window scene, controls, Now Playing, power notifications, display attachment, PiP window restoration, user interaction | playback authority or writable engine state |
| `SuperplayrPlaybackStateSpace` | bounded environment ledgers, structural search keys, deterministic exploration, replay artifacts, progress analysis | duplicated playback policy, media objects, framework execution, physical-correctness claims |

## Command and result flow

```text
SwiftUI/AppKit command
        |
        v
PlaybackCoordinator ---- persistence effect ----> atomic session store
        |
        v
deterministic PlaybackCore transition
        |
        v
scoped effect + authority context
        |
        v
native executor / renderer / platform adapter
        |
        v
typed result + matching generation/fence
        |
        v
immutable PlaybackViewSnapshot ----> reactive shell
```

Only an accepted result may advance authoritative state. Duplicate completions
are idempotent; stale generations cannot resume playback, present frames, commit
subtitles, or overwrite a newer seek.

Every asynchronous native effect is represented by an immutable
`NativeOperationTransaction`. It carries the core effect and operation IDs,
core session/generation authority, native session/generation correlation,
requested state, deadline, and cancellation state. `NativeOperationLedger`
indexes that identity by effect and, once known, exact native generation. A
callback can therefore complete only its originating effect; supersession,
deadline expiry, and shutdown cancel the old transaction rather than reusing a
mutable pending slot. Cancellation removes the transaction and its correlation
immediately. A missing identity rejects a late callback, so superseded seeks that
never produce callbacks cannot accumulate cancellation tombstones. Native
session/generation identities are not reused for later seek operations. Resource
leases and physical worker cleanup remain separate from this result ledger.

Chapter selection resolves to the same core-issued exact seek as timeline
selection; the runtime protocol has no separate chapter operation. The product
coordinator keeps its mutable projection internal and exposes `PlaybackViewStore`
to the app and external consumers.

`SuperplayrPlaybackStateSpace` drives this same production transition function;
it does not contain a second reducer. Its executor prerequisite bits describe
when an aggregate native acknowledgement may be scheduled, not proof that a
decoder or renderer physically performed that work. Recovery prerequisites are
an explicit dependency chain: old-output fence, decoder teardown, software
configuration, presentation membership, then required-stream preroll. The
explorer applies per-case wall-clock limits, emits layer progress, records
source revision/dirty identity in every result, and can resume completed jobs.

Filesystem preparation uses the shared `SourcePreparationExecutor` utility in
`SuperplayrCore` (separate from the deterministic `SuperplayrPlaybackCore`).
Product open/restore/folder preparation and native external-subtitle reads share
two physical worker slots and twelve-second logical deadlines. Cancellation or
timeout retires the waiter while stalled OS work retains its slot. Source and
operation revisions still decide whether a completed result may be published.

## Presentation and subtitle authority

The normal video path remains direct:

```text
FFmpeg -> VideoToolbox/software decode -> CMSampleBuffer
       -> AVSampleBufferDisplayLayer
```

Software output reserves one of seven end-to-end frame permits before checking
out a pixel buffer. Pool saturation therefore blocks under generation-aware
cancellation instead of becoming a timed fatal error. VideoToolbox decode
recovery resumes the existing FFmpeg decoder after the first two consecutive
failures; the third consumes the lineage's single software-fallback budget.
The session retains one bounded compressed-video GOP beginning at a keyframe.
Software fallback replays that GOP into the replacement decoder and rejects
output through the already-submitted video horizon, so audio, subtitles, and
the presentation clock continue without a full media seek. If no bounded
keyframe replay is available, recovery falls back to an exact seek.

Core Audio device discovery publishes a read-only stream/speaker capability
snapshot. AudioDecoder negotiates 2/6/8-channel PCM at 48 kHz, with conservative
stereo fallback, through a small synchronized snapshot shared by the existing
presentation coordinator. Both swresample and sample-buffer descriptions use
explicit canonical speaker identities. Output layout changes participate in the
existing audio format revision and route-recovery transactions; renderer/clock
ownership stays with presentation and recovery decisions stay in PlaybackCore.

The product selects bounded planar software output for supported eight-bit
NV12 and ten-bit P010 input, with full and limited range. The decoder preserves YUV code values
and color/geometry attachments, retains hardware-owned buffers when available,
and uses the existing BGRA fallback for unsupported input or conversion/pool
failure. Failed conversion pins fallback for the current generation. The same
capacity, format-revision and seek fences apply to both software routes.
4:4:4 and greater precision remain fallback cases.

VideoDecoder owns synchronous automatic BWDIF filtering for flagged interlaced
YUV frames. The filter retains a bounded temporal window, uses two native filter
threads, and emits one progressive frame per field through existing queue
admission. Progressive input bypasses filtering until needed. EOF drains delayed
fields; seek, decoder replacement and fallback discard them. Format changes drain
the old graph before rebuilding, including color-range/matrix changes. Hardware
input takes an explicit software transfer path; unsupported formats or inputs
above 32 MiB fall back to source fields with diagnostics. This introduces no
additional presentation loop, clock or recovery authority. Manual overrides and
general video-filter controls remain unsupported.

The PGS decoder adapter retains at most two composition references and applies
their crop rectangles while copying FFmpeg's palette pixels. It preserves the
composition destination and resets metadata with the existing bitmap decoder
seek lifecycle; pixel decoding and object caching remain in FFmpeg.

The main window draws text and embedded PGS/DVD/DVB subtitles in a separate Metal overlay. It does not
composite ordinary video frames. PiP composition has its own subtitle pipeline,
compositor, and display-layer host and is enabled only for the eligible
subtitle-composited PiP mode. Initialization or runtime failure falls back to
video-only PiP without changing the main direct-presentation path. SDR P010
composition uses packed ten-bit RGB output; BGRA/NV12 uses BGRA8. The output pool
includes pixel format in its key. Optional ten-bit Metal pipelines preserve the
existing eight-bit path when unavailable. Supported PQ/HLG P010 frames use one
reusable linear RGBA16Float texture bounded to 64 MiB, then return to tagged P010.
Caption white is 203 cd/m²; HLG uses the 1,000-nit reference OOTF and inverse.
GPU and Apple displayed-buffer tests retain P010 on the current host; physical
display precision, brightness and tone mapping remain unqualified.

The main view is hidden during composited PiP, but its renderer continues to
receive samples because it supplies the session's decode-demand gate. Restoration
reveals that timestamped renderer rather than displaying the latest prefetched
frame. The PiP pool remains limited to 12 buffers. Allocation-threshold pressure
retains one pending frame and resumes on Core Video's
[buffer-return notification](https://developer.apple.com/documentation/corevideo/kcvpixelbufferpoolfreebuffernotification),
without polling or dropping captions. Other composition failures retain the
existing video-only fallback. The pool observer follows the pool's lifetime.

Text is typeset by libass into an R8 atlas. Bitmap display sets retain palette
color/alpha as premultiplied BGRA regions in a separate atlas format. The same
pipeline owns generation invalidation, bounded display-set lifetime, forced-event
filtering and cached redraw. PGS lasts until its next display set; DVD uses
explicit expiry. Seeking reconstructs PGS from an acquisition/epoch through the
existing independent subtitle input, with bounded packet/byte search. Source
pixels are scaled by Metal quads, without CPU resizing or a second clock owner.

`NativePlaybackRuntime` owns one committed `activeSessionID` and one explicit
`NativeSubtitleSource`: off, automatic embedded, a specific embedded stream, or
an external URL. Prepared external bytes are only a cache for that source; they
are not selection authority. External and off modes cannot silently ingest an
embedded subtitle stream during an audio-track or media-session replacement.

Each replacement candidate owns independent main-window and PiP
`SubtitlePipeline` instances. They may parse and preroll against the stable
overlay resources, but presentation authority is disabled until commit. The
main and PiP pipelines are switched together with the active media session.
Retired or rolled-back pipelines are cleared and terminated without being able
to overwrite the committed subtitle source.

`NativePlaybackRuntime` owns one `SubtitleMemoryBudget` shared by the committed
and candidate main/PiP pipelines and the PiP compositor. It reserves bounded
libass cache capacity and accounts reusable CPU staging before growth. Main and
PiP owners have separate sublimits within a 192 MiB application cap. If PiP
cannot acquire staging capacity, its compositor emits the video-only frame;
this does not affect the main Metal overlay or direct video presentation.

## Transactional replacement

File replacement, audio-track replacement, and subtitle-source replacement use
one candidate protocol:

1. Construct, probe, configure, and begin bounded decode work in a candidate
   `MediaSession` while the committed session continues presenting.
2. Require the candidate's selected audio/video streams to produce their first
   decoded samples before it can acquire the shared presentation graph.
3. At commit, quiesce the old graph, install a presentation fence, atomically
   switch the active session and subtitle pipelines, and start candidate
   presentation at rate zero.
4. Retain the old session until the candidate reaches actual renderer preroll.
   Only then apply the current requested rate and retire the old workers.
5. On construction, decode-preroll, native commit, deadline, or pre-preroll
   renderer failure, revoke candidate authority and restore the old native
   session, native source/session identity, native track intent, presentation
   membership, position, and rate.

A seek received during candidate preparation updates the candidate's commit
target. Superseded candidates are generation-fenced and cannot steal
`activeSessionID`, presentation membership, or subtitle authority.

The deterministic core holds a heap-boxed immutable `pendingSession` while its
`activeSession` remains committed authority. `PlaybackRuntimeDriver` does not
switch its event gate until the candidate's identified preroll result commits
that pending session. `PlaybackCoordinator` likewise holds requested playlist,
source metadata, external subtitles, settings, and restore target in a
`PendingSourceTransaction`; it publishes and persists them together only after
the core snapshot identifies the candidate as active. Failure or supersession
discards pending state without reverse-restoring product state. EOF advancement
and repeat-one reload use the same transaction.

## Runtime rules

- Media input opens off the main actor and has targeted cancellation. A bounded
  quarantine with a fixed worker/memory budget handles native reads that cannot
  return immediately. A read cancellation remains sticky across admission until
  an accepted seek or terminal input teardown consumes it.
- Packet and frame queues are bounded by count and, where applicable, bytes and
  duration. Renderers supply sample demand through readiness callbacks.
  A synchronizer media-time observer requests subtitle updates at the source's
  nominal cadence (bounded to 24–120 Hz; 30 Hz when unknown). With subtitles Off,
  a 4 Hz observation still completes EOF drain. Callbacks coalesce before UI
  delivery and stop repeating on a paused timeline. Resize/exposure and subtitle
  delay changes explicitly request paused redraw. Observation does not feed
  audio/video samples or guarantee exact displayed-frame timing.
- A seek installs one generation and waits for demux cancellation, decoder flush,
  queue flush, presentation fence, subtitle invalidation, and preroll before rate
  restoration. Exact audio seeks trim to the first sample at or after the target.
- Wake is an identified native transaction. It performs the authorized exact
  seek/re-preroll and reapplies the captured requested presentation rate only
  after the matching native generation reaches preroll; a stale wake cannot
  resume a replacement session.
- Renderer membership covers audio/video, video-only, audio-only, and zero-output
  sources. EOF is emitted after decoder drain and presentation-horizon drain;
  the core emits playlist advancement only after the EOF checkpoint succeeds.
  A failed write or intervening playback operation prevents that advancement.
- Hardware decode recovery is budgeted once per media-session/video-stream
  lineage. Presentation recovery escalates from scoped flush to graph rebuild to
  terminal failure.
- Demux read recovery distinguishes EOF and cancellation from bounded corrupt or
  transient read failures. Retry counts reset after packet progress and a
  wall-clock bound prevents a non-advancing input from spinning indefinitely.
- Audio and subtitle workers are optional-track fault domains. Subtitle input
  failure clears and disables only subtitles. Sustained audio decode failure
  disables audio when video remains, while audio-only media retains a terminal
  failure. Audio presentation recovery escalates from flush to renderer rebuild
  before video-only degradation.
- Dynamic audio and video formats are observed as typed, revisioned facts.
  `MediaSession` holds the new-format frame behind a stream/revision ticket until
  the matching core-authorized reconfiguration completes. Wrong or stale
  revisions cannot release the barrier; exhaustion and bounded-wait expiry are
  typed presentation failures.
- Video format identity comes from decoded-frame geometry and metadata: coded
  and display size, crop/aperture, SAR, rotation, pixel format, chroma location,
  range, color fields, and HDR payloads. Large timestamp discontinuities create
  a new presentation segment; isolated backward timestamps are discarded.
- Native code measures starvation, clocks, drift, and format changes at bounded
  reporting intervals. The core alone chooses buffering, rate, drift, format,
  and recovery policy; framework calls stay in identified native effects.
- Resource leases distinguish logical invalidation from physical release. The
  application callback tombstone permits cleanup-only callbacks after terminal
  shutdown and rejects ordinary state mutation.

## Application and platform lifecycle

The app declares one `Window("Illiquid", id: "player")`, not a player
`WindowGroup`; Settings is a separate scene. `AppModel` is application-lived.
Closing the player window detaches window-local monitors and observers but does
not terminate playback authority, PiP, persistence, power handling, Now Playing,
or the ability to reopen the player through Dock activation or Finder open
events. A replacement window reattaches the existing native surface.

Power notifications, Now Playing publication, playback lifecycle observation,
and other high-frequency hooks are installed at application lifetime rather
than from a transient SwiftUI view. Finder-open requests are drained before
restore may claim source authority. Folder discovery uses retained,
generation-fenced tasks; a new scan cancels stale work, and shutdown cancels and
awaits every retained scan before releasing the runtime.

PiP uses an explicit `stopped -> starting -> active -> stopping` transition
model plus independent desired-active intent. A start requested while stopping
is replayed after stop completion. Controller callbacks are identity-fenced,
observers have single-owner teardown, and a bounded stop deadline performs local
cleanup if AVKit omits its callback. AVKit restore completion reports success
only after the single player window is open, visible, not miniaturized, and the
native video surface is attached to that window; cancellation or timeout reports
failure exactly once.

## Reactive shell

`PlaybackViewStore` publishes whole immutable snapshots. SwiftUI, Now Playing,
PiP controls, display policy, and power integration consume projections and send
commands back through `PlaybackCoordinator`; they do not mutate runtime truth.
Device-local preferences and resumable-session persistence remain outside the
playback reducer and are applied as explicit effects.

## Shutdown

Shutdown is idempotent and shares one in-flight physical-cleanup task/result.
The runtime first revokes new callback authority, cancels exact native
operations and owned construction/deadline/work tasks, stops PiP with its bounded
fallback, and gathers the active session, pre-commit candidates, a retained
rollback session, and background retirement tasks by object identity. Each
session loses subtitle authority before its workers and presentation resources
are stopped. The runtime then awaits worker termination and physical lease
release and reports an incomplete shutdown when a bounded native worker cannot
be reaped. `PlaybackRuntimeDriver` still invokes this physical cleanup if the
deterministic core rejects or invariant-fails its logical shutdown transition.

At the app boundary, window restoration, folder scans, observations, and
platform coordinators are cancelled or invalidated before the backend reference
is released. Ordinary callbacks cannot mutate state after the application
tombstone; cleanup acknowledgements and the terminal shutdown result may cross
it.

## Dependency boundary

`SuperplayrPlaybackCore` imports no Foundation runtime, AppKit, SwiftUI,
AVFoundation, VideoToolbox, CFFmpeg, CLibass, dispatch queues, locks, timers, or
wall clocks. `SuperplayrNativePlayback` is the sole FFmpeg/libass and Apple media
framework boundary. Package and bundle verification reject removed engine and
OpenGL dependencies.

Signed audio delay is an immutable MediaSession configuration. Nonzero offsets
use an independent FFmpeg input inside the existing audio decode worker and a
bounded sample mapping; no additional worker or clock is introduced. Replacement
uses the existing candidate commit/rollback path. Seek generation fences reset
mapped timestamps, trimming and bounded silence. Track changes retain the offset;
new media resets it to zero.

External VobSub uses the existing independent subtitle input and worker, with
codec parameters from the sidecar and a zero-based subtitle timeline. Shared
filesystem preparation validates the pair and bounds its index/catalog; candidate
construction verifies both file versions. Installed language IDs map to prepared
streams through the existing track selection effect. Product restoration waits
for the external catalog before matching the saved language or applying Off.

UI and persistence URL keys are lexical and never resolve symlinks. Canonical
filesystem identities are prepared on the shared bounded executor before new
source, folder, Locate or source-tab URLs are committed. Source requests retain
the existing coordinator generation; source-tab additions retain the destination
tab identity. Browser reads may wait asynchronously (at most 64) within one
12-second deadline while the two physical admission slots remain occupied until
actual OS work exits. Interactive source opens retain fail-fast admission.
