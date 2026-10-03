# Imperative Playback Core / Reactive Shell Refactor Plan

Status: historical architecture plan with implementation reconciliation. The
production FC/IS authority migration completed at
`6825c6b90c9bfdcd3f80391c177edc22a2523513` on 2026-07-20.

Evidence baseline: Superplayr HEAD `fbdc699627bebf4298a630004ca31a31b0ec5df4` (`feat: harden native playback and add picture in picture`, 2026-07-19).

Current authority and verification:
[FCIS_COMPLETION_MATRIX.md](FCIS_COMPLETION_MATRIX.md) and
[NATIVE_PLAYBACK_QUALIFICATION.md](NATIVE_PLAYBACK_QUALIFICATION.md). The plan's
“current” source descriptions, proposed type names, and stage estimates remain
dated to `fbdc699`; they are not rewritten as if `6825c6b` existed during the
audit.

Scope: macOS, the native FFmpeg + VideoToolbox/software decode + Apple sample-buffer presentation + libass backend, and the existing SwiftUI/AppKit product shell. The target architecture does **not** include a legacy mpv/OpenGL runtime path or a cross-platform playback abstraction. At the `fbdc699` baseline, existing legacy files could remain untouched in the tree while the native migration was qualified, but the new architecture never routed through them; migration rollback was to the immediately previous native slice, and legacy removal was the final planned gate.

## 1. Executive summary

The 2026-07-19 recommendation was that Superplayr perform this refactor **before
adding further native playback parity**, as a compilation-safe sequence of
extractions rather than a rewrite. That authority refactor is now complete. At
the baseline, the native components were useful and substantially qualified,
but the policy connecting them was not yet a deterministic system.

At baseline HEAD, high-level playback decisions were distributed across:

- `PlaybackState` and `PlaybackCoordinator` on the main actor;
- `NativeAppleBackend` on the main actor and a 100 ms wall-clock timer;
- `MediaSession` on six dispatch queues guarded by locks;
- decoder, presentation, and subtitle callbacks that can change playback policy directly.

That arrangement has source-confirmed correctness gaps at precisely the boundaries a deterministic core would own:

- old and new `MediaSession` instances can overlap while sharing `NativePresentationCoordinator` and `SubtitlePipeline`; generation checks are separate from final renderer/libass mutation;
- EOF means decoded frames were submitted, not that Apple renderers presented and drained them;
- VideoToolbox failure recovery is initiated by the decoder worker and performs a global seek itself;
- open/probe and external-subtitle reads can block the main actor and cannot be cancelled;
- loading, pause, seek, recovery, sleep/wake, stop, and shutdown each have partially duplicated or optimistic state;
- there is no general operation ID, resource lease ledger, virtual clock, event journal, deterministic fault injector, or replay format.

The proposed target is a small value-semantic `PlaybackCore` in a new dependency-light `SuperplayrPlaybackCore` target. A single serialized `PlaybackEventLoop` owns it. SwiftUI and AppKit send commands or platform facts into that loop and observe a read-only `PlaybackUISnapshot`. The core emits typed `PlaybackEffect` values; native executors own FFmpeg, VideoToolbox, sample buffers, libass, persistence, and platform objects. Every asynchronous effect and result is scoped by session, playback generation, logical operation, individual effect, stream/track, and resource revision as applicable.

The architecture is a deterministic **control plane** around a concurrent, batched **media data plane**. The reducer does not own or serialize pixels, PCM, `AVPacket`, `AVFrame`, or libass images. It authorizes bounded batches using opaque handles, observes value summaries, and decides lifecycle policy. A serialized commit fence inside the presentation and subtitle executors revalidates identity at the final framework mutation; reducer-side stale rejection alone cannot close the current check-then-enqueue race.

The migration should preserve the current native implementation behind adapters until each extracted behavior passes reducer tests, deterministic fault tests, generated-media integration tests, stress/teardown checks, and physical macOS qualification. Seeking/generation and final sink fencing should move first; loading/EOF/replacement and recovery follow; A/V startup/synchronization, subtitles/tracks, and the reactive shell follow after those foundations.

## Evidence status and report authority

All conclusions below were rechecked against the `fbdc699` source baseline.
Reports are supporting evidence, not substitutes for source. The table is the
original planning assessment, not a current file inventory:

| Evidence | HEAD assessment |
|---|---|
| `architecture-implementation-state-report.txt` | Historical baseline only. It inspected `d361d4c`, before the native POC and production backend seam. Its libmpv-only, no-native-test, and no-`PlayerBackend` conclusions are false at current HEAD. Its product/UI preservation discussion remains useful. The file is currently untracked. |
| `Documentation/NATIVE_PLAYBACK_POC_REPORT.md` | Still useful for low-level FFmpeg/VideoToolbox/sample-buffer/libass design and dated qualification evidence. Its claims that production was untouched and that `NativePlaybackController` owns the POC are obsolete. |
| `Documentation/PRODUCTION_PLAYBACK_INTEGRATION_REPORT.md` | Broadly accurate about the dual-backend seam, but committed at `d18a097`, before `ea1e22e` and `fbdc699` changed seeking, subtitles, hardening, PiP, replacement, and tests. Test and package counts are historical. |
| `Documentation/NATIVE_PLAYBACK_POC_MANUAL_QUALIFICATION.md` | Dated evidence for long runs, fullscreen, P010/HDR, and heavy ASS. Its physical sleep/display/audio/HDR/rotation checks remain open and it targets the POC harness. |
| `Documentation/MANUAL_PLAYBACK_CHECKLIST.md` | A useful product-behavior inventory, but every box is unchecked and several items are legacy-mpv-only. It is not native qualification evidence. |
| `Documentation/ARCHITECTURE.md` and `README.md` | Still describe a primarily libmpv architecture and are stale for the native control path. |
| `Documentation/MpvReferenceAnalysis/` | The strongest completed reference analysis. `SOURCE_PINS.md` pins this Superplayr HEAD plus exact mpv, FFmpeg, and libass revisions. Its baseline-source findings match this audit. The directory was untracked at the planning baseline and could not silently become release evidence until deliberately adopted. |

At the planning baseline, the checkout contained 79 `@Test` declarations and 16
`@Suite` declarations across five test targets in `Package.swift`. A fresh run
was attempted, but the selected Command Line Tools compiler and SDK did not
match; selecting full Xcode then failed because its license was not accepted.
That was an environment/toolchain block, not evidence of a source failure.

The completion run on 2026-07-20 supersedes that execution limitation: 119
tests in 20 suites passed with required fixtures, along with hostile
production-driver outcomes, architecture validation, fresh 12-reopen ASan and
TSan stress, three 60-second zero-drop A/V soaks, package/signature verification,
and live packaged-app smoke. This proves the authority switch described in the
completion matrix. It does not prove the unimplemented pinned mpv comparator,
every proposed edge fixture, or the full physical display/audio matrix.

## 2. Current architecture and control-flow map

### 2.1 Production module map

| Current module | Current role | Important paths and symbols |
|---|---|---|
| `SuperplayrCore` | Product models, mutable observable playback state, playlist logic, persistence. | `Sources/SuperplayrCore/Player/PlaybackState.swift` (`PlaybackState`), `Sources/SuperplayrCore/Player/PlaybackCommand.swift`, `Sources/SuperplayrCore/Player/PlaybackPhase.swift`, `Sources/SuperplayrCore/Player/MediaSource.swift`, `Sources/SuperplayrCore/Player/MediaTrack.swift`; `Sources/SuperplayrCore/Persistence/*`; `Sources/SuperplayrCore/Playlist/*`. |
| `SuperplayrPlayback` | Dual-backend-neutral protocol and event seam. | `PlayerBackend.swift` (`PlayerBackend`, `PlayerBackendKind`), `PlayerBackendEvent.swift` (`PlayerSessionIdentity`, `PlayerBackendEvent`, `PlayerEventGate`), `PlayerCapabilities.swift`, `PlayerSurfaceHost.swift`, `BackendSelection.swift`. |
| `SuperplayrNativePlayback` | Native backend, sourced from the historically named `Sources/SuperplayrNativePlaybackPOC` directory. | `Sources/SuperplayrNativePlaybackPOC/Production/NativeAppleBackend.swift`; `Sources/SuperplayrNativePlaybackPOC/Media/MediaSession.swift`, `Sources/SuperplayrNativePlaybackPOC/Media/FFmpegDemuxer.swift`, `Sources/SuperplayrNativePlaybackPOC/Media/VideoDecoder.swift`, `Sources/SuperplayrNativePlaybackPOC/Media/AudioDecoder.swift`; `Sources/SuperplayrNativePlaybackPOC/Presentation/*`; `Sources/SuperplayrNativePlaybackPOC/Subtitles/*`; `Sources/SuperplayrNativePlaybackPOC/Playback/*`. |
| `SuperplayrPlayer` | Product coordinator plus both native and legacy integration. | `Player/PlaybackController.swift` (`PlaybackCoordinator`, `PlaybackController` alias), `LegacyMpvBackend.swift`, `Mpv*.swift`, `ArchitectureValidation.swift`. It currently links `CMpv` and OpenGL as well as the native target. |
| `SuperplayrApp` | SwiftUI views and AppKit/macOS integration. | `Sources/SuperplayrApp/App/AppModel.swift`, `Sources/SuperplayrApp/App/AppDelegate.swift`, `Sources/SuperplayrApp/App/NowPlayingCoordinator.swift`, `Sources/SuperplayrApp/App/PlaybackSystemCoordinator.swift`; `Sources/SuperplayrApp/UI/PlayerRootView.swift`, `Sources/SuperplayrApp/UI/PlaybackControlBar.swift`, `Sources/SuperplayrApp/UI/PlaylistSidebar.swift`, `Sources/SuperplayrApp/UI/VideoSurface.swift`. |
| C system modules | Native library boundaries. | `Sources/CFFmpeg/include/ffmpeg_shim.h`, `Sources/CLibass/include/libass_shim.h`, and the legacy `Sources/CMpv`. |

The native backend is integrated but is not the default. `PlaybackPreferences.standard`, its initializer default, and decode fallback all select `.legacyMpv`; the settings label is “Native Apple (Experimental)” in `Sources/SuperplayrCore/Persistence/PlaybackPreferences.swift`. `PlayerBackendSelector.select` in `Sources/SuperplayrPlayback/BackendSelection.swift` can also fall back from native initialization to legacy. This is deployment reality to preserve during migration, not part of the target design.

### 2.2 Current ownership and concurrency

| Layer | Authoritative owner today | Execution context | Direct side effects |
|---|---|---|---|
| Window/UI | `AppModel`, SwiftUI views, AppKit coordinators | `@MainActor` | Window/fullscreen, panels, pointer/chrome timers, Now Playing, power assertions, workspace notifications. |
| Product orchestration | `PlaybackCoordinator` | `@MainActor` | Playlist selection, persistence writes, backend construction/calls, event gating, EOF advancement. |
| UI-facing state | `PlaybackState` | `@MainActor`, `@Observable` reference | Public lifecycle/timing/track/output mutators; views can invoke some mutators directly. |
| Native orchestration | `NativeAppleBackend` | `@MainActor` plus a 100 ms `Timer` | Session replacement, seek coalescing, track policy, subtitle rendering trigger, EOF/diagnostic emission. |
| Pipeline orchestration | `MediaSession` | `@unchecked Sendable`, `NSLock`, six possible serial `DispatchQueue`s | Demux/decode/presentation pumps, seek invalidation, preroll, EOF, renderer failure strings, VT recovery. |
| Native resources | Demuxer, decoders, presenters, libass | Worker queues and locks, often by convention | FFmpeg pointers, packet/frame allocation, VideoToolbox, synchronizer/renderers, libass track/renderer, overlay commits. |

There is one serialized path only **above** the backend: backend callbacks reach `PlaybackCoordinator.handle(_:)` on the main actor. Below it, high-level policy can originate on the main actor, demux queue, video/audio decoder queues, presentation queues, subtitle queue, timer, and AppKit callbacks.

### 2.3 Current native mechanics and enforced limits

- `FFmpegDemuxer` exclusively owns its `AVFormatContext`; `FFmpegPacket` moves and deinitializes one `AVPacket`. `VideoDecoder` owns its video codec/frame/codec parameters and `SwsContext`; `AudioDecoder` owns its audio codec/frame and `SwrContext`.
- `MediaSession` uses count-bounded `BoundedQueue`s: 96 video packets, 192 audio packets, 64 subtitle packets, 12 video frames, and 48 audio frames. Queue close wakes blocked producers/consumers. The bounds do not account for bytes or media duration, and data backpressure has no independent control-priority channel.
- Video decode uses FFmpeg’s modern send/receive API. VideoToolbox-backed frames retain `CVPixelBuffer`; software output is converted to IOSurface-backed BGRA. Audio is converted to fixed 48 kHz stereo float PCM; the `SwrContext` is configured from the first frame and not recreated for a later source-format change, and its delayed tail is not separately drained.
- `NativePresentationCoordinator` owns one `AVSampleBufferRenderSynchronizer`, `SampleBufferVideoPresenter`, and `SampleBufferAudioPresenter`, and currently attaches both renderers even when a stream is absent. It is `@unchecked Sendable` and is called from the main actor plus separate presentation queues. The audio presenter exposes readiness/enqueue/flush but not renderer error/status; video flush completion is ignored.
- `SubtitlePipeline` owns a locked `LibassContext`; `LibassContext` owns `ASS_Library`, `ASS_Renderer`, and `ASS_Track`. Embedded packet ingest, main-actor render/configuration, and main-queued overlay delivery cross execution contexts. `SubtitlePipeline.clear()` clears caches/overlay, not libass events.
- Existing useful mechanics include generation-tagged packet/frame/EOS values, seek-before-queue-clear invalidation, latest-pending seek coalescing, decoder send/receive draining, and one submitted item per required stream before `startIfPrerolled`. These are mechanics to preserve and strengthen, not proof of end-to-end deterministic policy.

### 2.4 Existing identity and stale-result defenses

- `PlaybackCoordinator.playbackGeneration: UInt64` plus `PlayerSessionIdentity(source:generation:)` identify a product file load. `PlayerEventGate` rejects old backend events.
- `folderScanGeneration: UUID` rejects stale detached folder-discovery results.
- `filterMutationTokens: [VideoFilterPreset: UUID]` reject stale asynchronous legacy filter mutations.
- `NativeAppleBackend.activeSessionID: UUID` changes on native session replacement, but currently guards only preview-seek completion.
- `PlaybackGeneration` is a session-local locked `Int`, advanced on seek, stop, and software recovery. It travels with `FFmpegPacket`, decoded frames, EOS markers, and `SeekRequest`.
- `presentedVideoGeneration`, `presentedAudioGeneration`, `startedGeneration`, `endedVideoGeneration`, and `endedAudioGeneration` record per-generation readiness/EOF.
- `videoSeekFloor` and `audioSeekFloor` reject pre-target output for non-preview seeks.
- `SeekCoordinator` keeps only the latest pending request and refuses an older completion to overwrite a newer phase.
- `didEmitEndOfFile` and `didEmitFirstFrame` de-duplicate timer-derived backend events.

There is no general operation ID for open, seek, track replacement, decoder recovery, flush, persistence, release, stop, or shutdown. The product identity, native replacement UUID, and session-local generation are not one end-to-end identity and are not validated atomically at final presentation or overlay mutation.

### 2.5 Flow-by-flow map

#### Application launch and restoration

- **Path:** `SuperplayrApp` → `AppModel.shared` → `AppModel.init(player:)` → `PlaybackCoordinator.init` → `PlaybackPersistenceStore.loadPreferences` → `PlayerBackendSelector.select` → backend construction. `VideoSurface.makeNSView` later calls `PlaybackCoordinator.makeVideoSurfaceHost()`. `AppModel.configure(window:)` calls `restoreLastSession()` once. Finder/LaunchServices URLs arrive through `AppDelegate.application(_:open:)`.
- **State/thread:** `AppModel`, `PlaybackCoordinator`, `PlaybackState`, preferences, and restore bookkeeping are main-actor owned. `PlaybackCoordinator.restoreLastSession` reads persistence and the filesystem; folder discovery uses `Task.detached`.
- **Effects/framework calls:** preferences/session I/O, file existence checks, folder enumeration, backend/native renderer/libass construction, AppKit surface creation.
- **IDs/defenses:** `folderScanGeneration` rejects an old scan; a pending native load is retained until a surface exists. Native init fallback is backend selection, not event identity.
- **Tests:** backend preference selection and persistence serialization are covered in `Tests/SuperplayrPlayerTests/PlaybackCoordinatorTests.swift` and `Tests/SuperplayrCoreTests/*`. There is no end-to-end launch/Finder-open/window-restore test. `PlaybackSessionRecord.wasPaused` is stored but restore currently auto-plays.
- **Core/runtime split:** the core should own restore intent, accepted restore result, session ID allocation, initial desired transport, and load sequencing. AppKit construction, Finder events, filesystem discovery, and persistence reads stay outside.

#### File loading

- **Path:** `AppModel.handleOpenURLs`, `openFilePanel`, or `openFolderPanel` → `PlaybackCoordinator.open/openFolder` → `playItem(at:origin:)`. `playItem` saves the old checkpoint, clears `PlayerEventGate`, calls `PlaybackState.beginLoading`, increments `playbackGeneration`, activates a `PlayerSessionIdentity`, calls `backend.load`, then immediately calls `backend.play`.
- **Native path:** `NativeAppleBackend.load(_:)` → `replaceSession(for:seekTo:emitLoaded:)` → stop old `MediaSession` without joining it → flush shared presentation → synchronously construct new `MediaSession` → start workers → emit `.loaded`, metadata, tracks, pause state.
- **State/thread:** product loading and playlist state live on the main actor; native desired state and selection live in `NativeAppleBackend`; native pointers live in `MediaSession` and children.
- **Effects:** persistence writes, session teardown, FFmpeg open/probe, decoder/libass setup, queue launch, renderer flush, backend event emission.
- **IDs/defenses:** product file identity gates events. The replacement `activeSessionID` does not tag frames or renderer commits. Old native workers can overlap the new session.
- **Tests:** resume-after-loaded in `PlaybackCoordinatorTests`; file replacement and stream fixtures in `NativePlaybackFixtureIntegrationTests`.
- **Core/runtime split:** atomic file replacement, desired play state, operation/session/generation allocation, old-resource release state, and result acceptance become core behavior. Opening and resource creation stay runtime work.

#### Stream discovery

- **Path:** `MediaSession.init` → `FFmpegDemuxer.init` → `avformat_open_input` → `avformat_find_stream_info` → `makeMediaInfo`/`bestStream` → `FFmpegMediaInfo`/`FFmpegStreamInfo`. `NativeAppleBackend.replaceSession` then emits `.loaded`/`.durationChanged`, calls `emitTracks()` and `emitVideoStatus(media:snapshot:)`, and emits chapters/pause state inline.
- **State/thread:** this currently occurs synchronously on the main actor during native load. `FFmpegDemuxer` owns `AVFormatContext`; discovered media metadata is static for the session.
- **Effects/direct calls:** FFmpeg input open, probing, best-stream selection, metadata/attachment extraction. There is no AVIO interrupt callback or cancellation path for blocked open/read.
- **IDs/defenses:** no open/probe operation ID. Stream identity is essentially FFmpeg stream index, translated to current `MediaTrack.id` values.
- **Tests:** container/stream discovery, codec matrices, multitrack, chapters, rotation/HDR/format metadata in `NativePlaybackFixtureIntegrationTests`.
- **Core/runtime split:** the runtime returns a value `MediaCatalog` scoped to an open operation. The core validates the result, owns requested/effective stable track IDs and catalog revision, and decides which decoders to configure.

#### Decoder initialization

- **Path:** `MediaSession.init` creates `VideoDecoder` and `AudioDecoder`; `superplayr_create_decoder` in `Sources/CFFmpeg/include/ffmpeg_shim.h` constructs codec contexts. Video initially requests VideoToolbox and can fall back at open. `AudioDecoder.init` opens the codec and allocates its `AVFrame`; it lazily creates the fixed 48 kHz stereo-float `SwrContext` on the first decoded frame in `convert`.
- **State/thread:** both decoders own an `AVCodecContext` and reusable `AVFrame`; video also retains copied codec parameters and a `SwsContext` as needed, while audio lazily owns a `SwrContext` and currently does not retain its own codec-parameter copy. Initial creation is on the main actor; subsequent use is decoder-queue confined by convention.
- **Effects:** codec selection/open, output-format configuration, pixel/PCM conversion setup.
- **IDs/defenses:** no decoder operation or resource revision. The selected stream index and session-local generation are not sufficient to reject a late decoder-creation result.
- **Tests:** hardware/software decoder construction, direct pixel-buffer retention, P010/HDR, codec and multichannel downmix fixtures. Runtime VideoToolbox failure is not deterministically injected through the whole session.
- **Core/runtime split:** the core owns decoder readiness, requested mode, revision, recovery budget, and typed failures. Executors own codec pointers and return configured/failed events.

#### Audio/video preroll and playback start

- **Path:** `MediaSession.start(rate:)` launches demux, video/audio decode, video/audio presentation, and subtitle workers. Presentation loops enqueue the first accepted samples, set `presentedVideoGeneration`/`presentedAudioGeneration`, and call `startIfPrerolled(generation:)`, which calls `NativePresentationCoordinator.setRate` after one enqueue for every selected A/V stream.
- **State/thread:** readiness is private locked state in `MediaSession`; `NativeAppleBackend.desiredPlaying` and `MediaSession.desiredRate` duplicate intent; `PlaybackState.phase` is a third product representation.
- **Effects/framework calls:** sample-buffer enqueue and `AVSampleBufferRenderSynchronizer.setRate`. Apple also has `delaysRateChangeUntilHasSufficientMediaData = true`.
- **IDs/defenses:** per-generation readiness markers exist, but `NativeAppleBackend.play` can call `MediaSession.setPlaying(true)` before internal preroll is complete. `.loaded` makes `PlaybackState` report `.playing`. `.firstFramePresented` is emitted when `framesSubmitted > 0`, which means enqueued, not displayed.
- **Tests:** native fixture tests exercise output, but no test proves the product cannot enter playing before required preroll.
- **Core/runtime split:** required-stream set, committed-sample preroll thresholds, desired/actual transport, and start legality belong in the core. Sink-capacity, enqueue commit, rate-request/effective-rate, and displayed/drained facts come from presentation executors; `isReadyForMoreMediaData` alone is never preroll.

#### Pause and resume

- **Path:** views/menu/Now Playing → `PlaybackCoordinator.play/pause/togglePause` → `NativeAppleBackend.play/pause` → `MediaSession.setPlaying` → synchronizer rate change → immediate `.pauseChanged` → `PlaybackState.setPaused` and checkpoint.
- **State/thread:** three owners currently track transport intent (`PlaybackState.phase`, `NativeAppleBackend.desiredPlaying`, `MediaSession.desiredRate`). All policy entrypoints are main actor; the actual clock belongs to the Apple synchronizer.
- **Effects:** direct synchronizer rate mutation, persistence checkpoint, Now Playing update.
- **IDs/defenses:** no operation ID or rate-application result. A pause/resume can race preroll, seek, recovery, or wake.
- **Tests:** native sleep/wake smoke observes pause-related behavior, but there is no dedicated coordinator play/pause forwarding test and no model of clock consistency across pause/resume.
- **Core/runtime split:** one desired transport state and legal transition table belong in `SynchronizationReducer`; the runtime applies rate and reports rate/clock state.

Current transport compatibility has two non-obvious cases that must be preserved or intentionally changed. In `PlaybackCoordinator.playItem(at:origin:)`, selecting the already active playlist item calls `play()` and does not reload or seek to persisted progress. Once EOF clears `PlayerEventGate`, selecting that same item falls through to a fresh load. Likewise, `PlaybackCoordinator.play()` reloads the selected playlist item when the gate has no active identity and `PlaybackState.phase` is `.idle` or `.failed`. After Stop this restarts from the beginning: `PlaybackState.markStopped()` sets position to zero, and the next `playItem` calls `saveCurrentProgress()` before load, overwriting the just-saved position with zero so restore does not seek. These rules belong in `SessionReducer`/`PlaylistReducer` command routing, with explicit regression tests, rather than emerging from gate population and checkpoint order.

#### Relative seeking

- **Path:** `PlaybackCoordinator.seek(relative:)` → `NativeAppleBackend.seek(to:mode:.relative)` → resolve against its timer-sampled `currentTime` → clamp → invoke the same session seek path as exact.
- **State/thread:** relative target calculation currently uses cached main-actor state sampled every 100 ms rather than an explicit clock fact.
- **Effects:** queue invalidation, subtitle clear, presentation flush, FFmpeg seek, decoder repreroll.
- **IDs/defenses/tests:** session-local generation protects data-plane output; there is no seek operation ID or completion event. Relative seek is indirectly exercised, not modeled against stale clock samples.
- **Core/runtime split:** the core resolves relative intent against its last accepted `ClockSample` and creates a seek transaction; the runtime supplies clock samples and performs the seek.

#### Exact seeking

- **Path:** `PlaybackCoordinator.seek(to:)` → `NativeAppleBackend.seek` → `MediaSession.seek` → generation advance/reset/queue clear/subtitle clear/presentation flush → `SeekCoordinator.submit` → `FFmpegDemuxer.seek` → decode forward → `acceptsVideo`/`acceptsAudio` floors → repreroll.
- **Current semantics:** `FFmpegDemuxer.seek(to:exact:)` ignores `exact` and always seeks backward. Exactness is a post-seek decode filter. Video rejects frames before target; audio accepts the whole PCM block whose end crosses the target rather than trimming pre-target samples. Same-media `MediaSession.seek` calls `presentation.flush(at:target, removeDisplayedImage:false)`, retaining the displayed frame while it reprerolls; replacement/stop use the default removing flush. Container `startTime` is not normalized; unknown duration becomes zero and clamps seeks to zero; invalid/missing timestamps lack a policy.
- **IDs/defenses:** each dispatched seek advances `PlaybackGeneration`; packets/frames/EOS are tagged; pending request coalescing exists. Seek failure can leave `SeekCoordinator` active, and exact completion is not returned as a product event.
- **Tests:** `latestSeekReplacesPendingSeek`, `completedOlderSeekCannotOverwriteNewPendingPhase`, `generationRejectsStaleOutput`, real rapid-seek fixtures. Missing: audio trim, near/at EOF, seek failure, dropped completion, malformed timestamps.
- **Core/runtime split:** the complete transaction, supersession, generation change, resume intent, exact/preview floors, completion/failure, and timeout belong in `SeekReducer`. FFmpeg landing and timestamp conversion remain runtime facts.

#### Preview seeking and rapid repeated seeking

- **Path:** `PlaybackControlBar.scheduleScrubSeek` sends preview seeks at roughly 33 ms; `NativeAppleBackend` keeps `pendingPreviewTarget`/`previewSeekInFlight`; `SeekCoordinator` retains the latest request. Scrub release sends a final exact seek.
- **State/thread:** coalescing is split between a SwiftUI task, backend timer state, and the session coordinator.
- **Effects:** repeated flush/seek/repreroll, preview frame marked display-immediately.
- **IDs/defenses:** `activeSessionID` plus generation guards preview completion; final exact supersedes pending preview. There is still no general operation ledger, and an accepted old enqueue can race final sink mutation.
- **Tests:** preview coalescing, latest pending, rapid 12-seek/shutdown fixtures. Missing: arbitrary reorder/duplicate/drop, seek during recovery, EOF during seek, and shutdown at every seek phase.
- **Core/runtime split:** core owns the latest preview target, debounce/deadline expressed through explicit tick events, one authoritative seek, and final-exact priority. SwiftUI may reduce UI chatter, but correctness cannot depend on its timer.

#### EOF

- **Path:** `MediaSession.demuxLoop` sends generation-tagged EOS → decoder loops call `VideoDecoder.drain`/`AudioDecoder.drain` and send decoded EOS → presentation loops consume EOS and call `markEnded` → when required streams are marked, synchronizer pauses and `MediaSessionSnapshot.ended = true` → `NativeAppleBackend.tick` emits `.endOfFile` once.
- **State/thread:** EOF state is locked in `MediaSession`; emission is timer-polled on the main actor. `markEnded` checks generation before taking its state lock, leaving a check-then-lock race.
- **Effects:** FFmpeg drain, queue EOS, synchronizer pause, product event.
- **IDs/defenses:** EOS carries internal generation, and `PlayerEventGate` rejects old-file EOF. The pipeline does not prove Apple renderer drain, and `AudioDecoder` does not explicitly drain delayed `SwrContext` output.
- **Tests:** `staleEventsAreRejectedAndEOFAdvancesPlaylist` proves one ordinary current EOF advances and a later old-generation position event is rejected. It does not inject duplicate current EOF or prove a dedicated once-only completion token. There is no renderer-tail, EOF-during-seek, delayed-frame, duplicate-current-EOF, or resampler-tail test.
- **Core/runtime split:** core owns explicit per-stream demux EOF → decoder drain → converter drain → samples submitted → presenter drained → final EOF states. Runtime supplies each fact; playlist completion cannot occur before all required current-generation stages finish.

#### Playlist advancement

- **Path:** `PlaybackCoordinator.handle(.endOfFile)` captures the URL, clears the event gate, calls `playNext()` or `PlaybackState.markStopped()`, and calls `PlaybackPersistenceStore.markPlaybackCompleted`.
- **State/thread/effects:** main actor owns cursor and performs persistence plus the next load. Deactivating/changing identity rejects repeated old-file EOF.
- **IDs/tests:** clearing/changing file identity gives partial protection after advancement. `staleEventsAreRejectedAndEOFAdvancesPlaylist` covers ordinary advancement plus a stale post-advance position event, not duplicate current EOF.
- **Core/runtime split:** `SessionReducer` owns the completion token; `PlaylistReducer` owns the accepted collection/cursor. The root consumes the token and advances the cursor atomically at most once. Folder discovery remains runtime input; persistence is an emitted effect.

Current playlist construction/restoration is also compatibility behavior, not merely filesystem plumbing. `PlaybackCoordinator.open(url:)` reuses the existing playlist when the file is already present; otherwise it creates a folderless singleton. `open(urls:)` chooses folder-open behavior when any directory is present, otherwise filters supported files and naturally sorts a folderless multi-file playlist. Folder restoration ignores the stored `PlaybackSessionRecord.playlistIndex` and selects `lastWatchedFile` when available, otherwise the first item. Stage 2 must trace these cases, and Stage 7 must either preserve them or attach an owner-approved semantic change.

#### Track switching

- **Path:** `PlaybackCoordinator.selectAudioTrack/selectSubtitleTrack` → `NativeAppleBackend`. Audio or embedded-subtitle changes call `replaceSessionForTrackChange`, stop the current session, create a new one at cached `currentTime`, and keep the same product identity. Subtitle-off mutates `SubtitlePipeline`; external subtitle loads use `Data(contentsOf:)` on the main actor.
- **State/thread:** requested/effective selection exists in backend/session/pipeline state. At the product/backend API, `selectAudioTrack(nil)` means automatic/default while `selectSubtitleTrack(nil)` means off, so a generic nil track command is ambiguous. Internally `MediaSession.init` applies `selectedAudioIndex ?? openedMediaInfo.selectedAudioIndex` and the analogous subtitle fallback to both; reconstruction therefore cannot use raw nil to preserve subtitle-off/external intent. Old and new native sessions can overlap on the shared sinks. The old playable path is destroyed before replacement succeeds, so failure cannot roll back.
- **Effects:** input/decoder recreation, seek, renderer flush, file read, libass track replacement, metadata emission.
- **IDs/defenses:** new `activeSessionID`, same `PlayerSessionIdentity`, no track revision or track-switch operation ID.
- **Current limitation/tests:** an audio-track replacement while an external subtitle is selected rebuilds the session with no selected subtitle index, resets/reconfigures libass to the default embedded/no-subtitle state, then overwrites backend selection from the replacement. With no embedded stream, `emitTracks()` can still report the external track selected even though its libass data was reset. Existing tests cover multitrack metadata, audio replacement teardown, and embedded/external subtitle fixtures; missing are this cross-track regression, rapid switches, switch during preroll/seek/recovery, and rollback on failure.
- **Core/runtime split:** core owns requested/effective track, prepare/commit/rollback transaction, track and decoder revisions, generation invalidation, and subtitle clear. Executors prepare new resources and report readiness before the core commits.

#### VideoToolbox failure and software fallback

- **Path:** `MediaSession.videoDecodeLoop` catches a decode error → `recoverVideoDecoderFromHardwareFailure` → `VideoDecoder.switchToSoftware()` → sample synchronizer time → call `MediaSession.seek` → resume. The decoder queue makes this high-level decision.
- **State/thread/effects:** recovery is worker-owned; it recreates codec state, flushes shared sinks through a seek, and changes metrics. A late error can recover after stop/replacement and affect shared presentation.
- **IDs/defenses:** seek generation invalidates old frames; there is no recovery operation/session guard. The direct test invokes decoder recreation, not a full injected VideoToolbox failure.
- **Tests:** `recreatesSoftwareDecoderAfterHardwarePathFailure`; rapid-seek test only bounds observed fallback count. `PlaybackCoordinator.handle(.decoderChanged)` currently loses reliable hardware/fallback semantics when it stores only a decoder string.
- **Core/runtime split:** executor reports a typed hardware failure. `RecoveryReducer` decides retry/recreate/software fallback/fatal policy, advances generation, and waits for scoped results. Decoder workers never initiate global seek or mutate UI state.

#### Subtitle loading, rendering, and clearing

- **Path:** subtitle worker → `SubtitlePipeline.process` → locked `LibassContext.processChunk`; main-actor timer → `MediaSession.renderSubtitles` → `SubtitlePipeline.render` → main-queue assignment to `SubtitleOverlayView.regions` (or `clear()`). External load performs synchronous `Data(contentsOf:)`, custom SRT-to-ASS conversion, and libass replacement.
- **Restore-sidecar behavior:** `PlaybackCoordinator.restorePositionAndExternalSubtitles()` iterates every matched sidecar, sending the first with `select:true` and later files with `select:false`. Once `NativeAppleBackend.externalSubtitleTrack` exists, `loadExternalSubtitle` rejects those later nonselecting calls, so only the first matched sidecar is actually loaded/exposed today—not merely selected first.
- **State/thread:** `SubtitlePipeline` is shared across sessions. Its caches/libass calls use mixed main/worker access; overlay delivery is asynchronous.
- **Effects:** filesystem read, font attachment registration, libass parsing/rasterization, AppKit overlay mutation.
- **IDs/defenses:** embedded packets carry generation, but rendered regions and overlay commits do not. `clear` clears caches/overlay but not libass track events; an embedded worker can continue inserting into a newly loaded external track. There is no subtitle revision or load/render operation ID.
- **Tests:** embedded/external SRT/ASS, font, geometry, paused-seek invalidation, heavy ASS. Missing: old render after replacement, embedded/external mixing, and track-revision races.
- **Core/runtime split:** the core owns subtitle intent and policy, with one owner per fact: `TrackSelectionReducer` owns requested/effective off/automatic/embedded/external selection and enable semantics, `ControlReducer` owns requested/effective subtitle delay, and `SubtitleReducer` owns the installed libass source/revision, visible-clear obligation, and render acceptance. A serial subtitle executor owns libass; a main-actor overlay commit validates the same revision again.

#### Sleep and wake

- **Path:** `PlaybackSystemCoordinator` observes `NSWorkspace.willSleep/didWake` → `PlaybackCoordinator.systemWillSleep/systemDidWake` → backend methods. Both coordinator and `NativeAppleBackend` save a resume boolean; both issue pause/play. Native wake exact-seeks to cached position before resuming.
- **State/thread/effects:** duplicate main-actor policy, persistence checkpoint, renderer pause, wake seek/repreroll, display refresh, idle-sleep assertion.
- **IDs/defenses:** no lifecycle operation ID; delayed wake/recovery can race replacement. Physical sleep/wake remains an open manual gate.
- **Tests:** backend simulation in `sleepWakeAndRepeatedTeardownRemainSafe` only.
- **Core/runtime split:** `LifecycleReducer` owns one resume-after-wake decision and wake transaction. `PlaybackSystemCoordinator` only reports notifications and executes platform effects.

#### Fullscreen and display changes

- **Path:** `AppModel.toggleFullscreen` calls `NSWindow.toggleFullScreen`; window notifications call `PlaybackCoordinator.setFullscreen`; `PlaybackSystemCoordinator` observes screen changes; `NativePlayerNSView.updateDisplayConfiguration` updates scale/EDR and emits `NativeDisplayCapabilities`; backend emits `.displayChanged`.
- **State/thread/effects:** AppKit/main actor owns window and surface. `PlaybackState` currently also stores fullscreen/display fields.
- **IDs/defenses:** no display revision. Main-queued callbacks can arrive after surface/session replacement.
- **Tests:** display-capability value, resizing/rotation/subtitle geometry; physical display moves/disconnects and fullscreen grading remain manual.
- **Core/runtime split:** fullscreen/window chrome remain shell state. Core receives value display/surface availability events only where they alter presentation readiness, recovery, or diagnostics; runtime owns `NSWindow`, `NSScreen`, layers, and EDR configuration.

#### File replacement

- **Path:** `PlaybackCoordinator.playItem` allocates a new product identity; `NativeAppleBackend.replaceSession` stops the old session without waiting and starts a new session on the same `NativePresentationCoordinator` and `SubtitlePipeline`.
- **State/thread/effects:** product state is main actor; old worker queues may still be executing while new resources and sinks are active.
- **IDs/defenses:** product events are gated and old session generation advances. But session-local generations restart, frames do not carry product/native session identity, and final `accepts` checks are not atomic with `renderer.enqueue`, `setRate`, libass mutation, or overlay delivery.
- **Tests:** `fileAndAudioTrackReplacementTearsDownOldSession` manually stops/creates `MediaSession` instances with shared sinks and checks eventual shutdown/no reported renderer failure. It does not execute `NativeAppleBackend.replaceSession` or prove production callback fencing.
- **Core/runtime split:** the core advances a globally scoped session before replacement effects. Presentation/subtitle executors install a serialized commit fence. Old callbacks are rejected at final mutation and yield cleanup-only effects. Old leases remain tracked until release completion.

#### Stop and shutdown

- **Stop path:** `PlaybackCoordinator.stop` checkpoints, clears the event gate, marks stopping, calls backend stop, then optimistically marks stopped. `NativeAppleBackend.stopCurrentSession` calls `MediaSession.stop()`, which advances generation and closes queues, then calls `SubtitlePipeline.clear()` (cache/overlay only; libass events remain) and `NativePresentationCoordinator.stop()` (rate zero plus renderer flush). Those calls do not release the shared resources or reset libass. The backend waits only in an untracked detached task. Backend `.stopped` is rejected because the product gate was already cleared.
- **Shutdown path:** `AppDelegate.applicationShouldTerminate` → `AppModel.shutdown` → stop Now Playing/system/window observers → `PlaybackCoordinator.shutdown` → checkpoint/mark shutting down/surface shutdown → remove backend reference → await backend shutdown. Native invalidates the timer, stops PiP/current session, waits at most three seconds, clears sinks, and emits `.shutdownCompleted` even after timeout. Earlier detached session waits are not included.
- **State/thread/effects:** terminal policy spans AppDelegate, AppModel, coordinator, backend, and worker joins. Commands other than load/surface creation are not uniformly guarded after shutdown starts.
- **IDs/defenses:** `isShuttingDown`/`isShutdown` booleans and one current-session wait; no shutdown operation, resource lease ledger, or global quiescence proof.
- **Tests:** once-only forwarding, repeated teardown, rapid-seek shutdown. Missing: shutdown during each phase, dropped release completion, timeout policy, no post-terminal work, and all-leases-released proof.
- **Core/runtime split:** core owns stopping/shutdown phase, accepted commands, the cleanup-only `.shuttingDown` rule, outstanding logical leases, timeout events, and terminal completion. Executors cancel/join/flush/release and return explicit results; `.terminated` is entered only after subscriptions, executors, and leases are acknowledged quiescent and then emits no effects. AppDelegate replies `.terminateNow` only after the published terminal result or an owner-approved forced-termination policy.

### 2.6 Existing tests, harnesses, diagnostics, and packaging

Current reusable evidence includes:

- `Tests/SuperplayrCoreTests/*`: lifecycle, persistence, playlist/folder discovery, media/track parsing, identity utilities, window sizing.
- `Tests/SuperplayrPlaybackTests/BackendContractTests.swift`: source+generation event gate, capabilities, native-init fallback.
- `Tests/SuperplayrPlayerTests/PlaybackCoordinatorTests.swift`: resume seek, stale event/EOF handling, playlist advancement, backend selection, shutdown idempotence, PiP.
- `Tests/SuperplayrAppTests/PlaybackChromeAndSidebarTests.swift`: shell-only pointer/sidebar behavior.
- `Tests/SuperplayrNativePlaybackPOCTests/NativePlaybackFoundationTests.swift`: rational time conversion, bounded FIFO/backpressure, generation rejection, submission-horizon metrics, latest seek, stale seek completion, display/viewport/subtitle geometry/font filtering.
- `Tests/SuperplayrNativePlaybackPOCTests/NativePlaybackFixtureIntegrationTests.swift`: synthetic FFmpeg demux/decode, VideoToolbox/software construction, HDR/P010, rotation/resizing, multichannel downmix, libass/fonts/heavy ASS, sleep/wake, teardown, preview coalescing, rapid seeking, replacement, codec matrices, and optional long runs.
- `Scripts/generate-native-poc-fixtures.sh`: broad generated, copyright-safe media fixtures.
- `Scripts/run-native-poc-qualification.sh`: fixture generation, tests, optional long gate, standalone ASan/TSan runs, repeated reopen/leak sampling, production build, and architecture check.
- `Sources/SuperplayrNativePlaybackPOCApp/NativePlaybackPOCApp.swift`: `--stress-cycles`, `--reopen-count`, timed-exit harness; useful but wall-clock/sleep driven.
- `Validation/SuperplayrArchitectureCheck/main.swift` and `ArchitectureValidation.run`: current product/legacy structural checks; little native lifecycle validation.
- `Scripts/verify-app.sh` and `Scripts/sign-and-notarize.sh`: reusable package, loader-path, signature, notarization, and staple validation.

Qualification caveats that must become explicit gates:

- most fixture tests `return` when `SUPERPLAYR_POC_FIXTURE_DIR` or an individual fixture is absent; no generated fixtures exist in this checkout;
- long-run coverage runs only when `SUPERPLAYR_POC_LONG_RUN_SECONDS` is set;
- `MediaSessionSnapshot` and `AVSyncStabilityMetrics` measure submitted queue horizons, not displayed/audible output;
- `firstFramePresented` is an enqueue fact, `framesDropped` is never incremented, audio renderer errors are not surfaced, and shutdown completion is emitted after timeout;
- there is no CI workflow in the repository, deterministic fuzz target, event replay, virtual clock, model runtime, or fault-injection layer;
- `Scripts/build-app.sh` and `Package.swift` still link/package mpv and OpenGL. `Scripts/build-native-poc-app.sh` is the existing native-only closure prototype. `verify-app.sh` and signing can remain after the dependency set changes.

## 3. Problems the refactor solves

The refactor is justified by behavior and ownership, not by a preference for reducer terminology.

1. **One policy authority.** Load, transport, seek, EOF, recovery, lifecycle, and shutdown decisions become synchronous state transitions instead of timing-dependent mutations across actors and queues.
2. **End-to-end identity.** Product file identity, native session identity, seek generation, decoder revision, subtitle revision, and operation completion become one explicit scope checked at every boundary.
3. **Replayable timing.** Clock reads, debounce, timeouts, checkpoints, and lifecycle deadlines arrive as values, so the same ordered input produces the same state and effects.
4. **Closed stale-output barriers.** Final presentation/libass/overlay commits revalidate the current scope on one serialized executor, closing the source-confirmed check-then-act race.
5. **Honest readiness and EOF.** Loaded, preroll-ready, submitted, displayed/audible, draining, and ended become distinct facts.
6. **Typed recovery.** Decoder/demux/renderer/subtitle failures return to policy; workers cannot decide to seek, replace, advance a playlist, or mutate UI.
7. **Quiescent shutdown.** Every long-lived and batched logical resource has a lease; `.shuttingDown` may emit final checkpoint and cleanup effects, while `.terminated` means all tracked work is quiescent and emits nothing.
8. **Model-based testing.** Reorder, duplicate, delay, drop, and fault transformations can run without FFmpeg or Apple frameworks, and failures serialize into permanent regressions.
9. **Safer parity work.** mpv behavior can be translated into scenarios and invariants without importing mpv architecture or C implementation details.
10. **Safer AI-assisted maintenance.** Pure transition code, explicit effect contracts, invariant checks, replay fixtures, and architectural import rules sharply reduce invisible lifetime coupling.

## 4. Proposed target architecture

### 4.1 Module and process shape

Create a new `SuperplayrPlaybackCore` Swift target beside the current implementation. It should depend only on the value types it needs from `SuperplayrCore`; it must not import AppKit, SwiftUI, AVFoundation, VideoToolbox, CFFmpeg, CLibass, Observation, or concrete persistence types. A dedicated target gives architecture validation a real dependency boundary; putting the reducer into the current `SuperplayrPlayback` target would inherit AppKit through `PlayerSurfaceHost`.

```text
SwiftUI views / AppKit coordinators                 @MainActor
        │ commands and platform value events
        ▼
PlaybackViewStore (read-only snapshot publisher)   @MainActor
        │
        ▼
PlaybackEventLoop                                  one serialized mailbox
        │ owns
        ├── PlaybackCore.update(event) -> PlaybackTransition
        ├── event/effect/rejection journal
        └── snapshot derivation
        │ ordered effect submission
        ▼
NativePlaybackRuntime
        ├── FFmpegInputExecutor
        ├── VideoDecodeExecutor
        ├── AudioDecodeExecutor
        ├── PresentationExecutor + commit fence
        ├── SubtitleExecutor + overlay commit fence
        ├── PersistenceExecutor
        ├── PlatformExecutor                         @MainActor
        ├── DiagnosticsExecutor
        └── ResourceRegistry / ShutdownExecutor
        │ completion/failure events with same scope
        └──────────────────────────────────────────► PlaybackEventLoop
```

Target dependency direction:

```text
SuperplayrCore values
        ↑
SuperplayrPlaybackCore (pure machine)
        ↑
SuperplayrNativePlayback (native executors)
        ↑
SuperplayrPlayer (event loop, runtime composition, migration adapters)
        ↑
SuperplayrApp (SwiftUI/AppKit shell)
```

The long-term native-only target removes `PlayerBackendKind`, `PlayerBackendSelector`, `LegacyMpvBackend`, `Mpv*`, `CMpv`, and OpenGL. During migration, the current native backend can be wrapped as a coarse executor or run as a comparison path, but no new event/effect type should mention mpv or a generic backend.

### 4.2 Deterministic control plane, batched data plane

The core should see semantic, bounded batches rather than bytes or pixels:

1. Core emits a context-bearing packet-read grant with item/byte/media-duration credit.
2. Demux executor splits mixed input into per-stream child batch leases, returns descriptors plus occupancy deltas, and retains the parent until every child has a disposition.
3. Core emits context-bearing decode effects for the relevant child lease.
4. Decoder returns frame descriptors plus opaque handles.
5. Core emits enqueue effects only when the current generation/revision is eligible.
6. Presentation executor revalidates authority/revisions **inside its serialized commit gate**, then commits or returns `.rejectedStale` with an exact lease disposition.

Batching keeps event rate practical while retaining deterministic queue counts and fault points. The core never examines packet bytes, pixel buffers, PCM, or subtitle bitmaps. Long-lived codec/input objects and reusable `AVFrame`s stay executor-local; only explicitly retained/movable packet, pixel, PCM, sample-buffer, or render batches cross an executor boundary. Executors may optimize within an authorized batch, but may not change track, seek, fall back, start playback, declare EOF, advance playlist, or mutate UI without a core effect.

### 4.3 The authoritative serialized path

`PlaybackEventLoop` should own the only mutable `PlaybackCore`. Every SwiftUI command, AppKit notification, timer/tick, FFmpeg result, decoder callback, presentation callback, subtitle result, persistence completion, and release completion enters its mailbox as an immutable `PlaybackEventEnvelope`.

For each dequeued event, the loop performs one non-reentrant transaction:

1. assign a monotonically increasing journal sequence and record virtual/monotonic time supplied by the envelope;
2. synchronously call `core.update(event)` with no `await` and no framework call;
3. derive and publish `PlaybackUISnapshot` if it changed;
4. journal accepted/rejected status, state digest, and ordered effects;
5. submit effects in returned order without awaiting their completion.

Concurrent runtime completion order remains externally nondeterministic, but the mailbox chooses and records one total order. Replaying that order is deterministic. The event loop must not await an executor while reducing; executor completion always comes back as another event, avoiding Swift actor reentrancy as a hidden transition path.

Effects sent to the same executor preserve submission order. Different executors may complete in any order. Multi-phase operations do **not** rely on submission order for completion ordering: the core emits only the current phase, waits for matching result events, then emits the next phase.

## 5. Proposed state model

### 5.1 Identity and time values

Use checked, monotonic integer allocation stored in core state. Do not generate UUIDs or read time inside `update`.

```swift
public struct PlaybackSessionID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UInt64
}

public struct PlaybackGenerationID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UInt64
}

public struct ApplicationEpochID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UInt64
}

public struct PlaybackOperationID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UInt64
}

public struct PlaybackEffectID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UInt64
}

public struct PlaybackSubscriptionID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UInt64
}

/// Stable result-case code used by the ledger/replay.
public struct EffectResultKind: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
}

public struct ResourceLeaseID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UInt64
}

public struct ResourceBatchLeaseID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UInt64
}

public enum ResourceLeaseKey: Codable, Hashable, Sendable {
    case single(ResourceLeaseID)
    case batch(ResourceBatchLeaseID)
}

public struct ResourceBorrowID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UInt64
}

public enum PlaybackStreamKind: String, Codable, Hashable, Sendable {
    case video, audio, subtitle, attachment, data, unknown
}

public struct PlaybackStreamID: Codable, Hashable, Sendable {
    public let kind: PlaybackStreamKind
    public let demuxIndex: Int32
}

/// A user-selectable audio/subtitle track; video/attachments use PlaybackStreamID.
public struct PlaybackTrackID: Codable, Hashable, Sendable {
    public let kind: MediaTrackKind
    public let mediaTrackID: Int64
}

public struct TrackRevisionID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UInt64
}
public struct DecoderRevisionID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UInt64
}
public struct MediaFormatRevisionID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UInt64
}
public struct PresentationRevisionID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UInt64
}
public struct PresentationGraphRevisionID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UInt64
}
public struct PresentationMembershipRevisionID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UInt64
}
public struct SubtitleRevisionID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UInt64
}
public struct SurfaceRevisionID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UInt64
}
public struct SurfaceID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UInt64
}
public struct DisplayRevisionID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UInt64
}
public struct PictureInPictureControllerID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UInt64
}
public struct BorrowRevisionID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UInt64
}

public struct PlaybackRevisionSet: Codable, Hashable, Sendable {
    public let track: TrackRevisionID?
    public let decoder: DecoderRevisionID?
    public let videoFormat: MediaFormatRevisionID?
    public let audioFormat: MediaFormatRevisionID?
    public let presentation: PresentationRevisionID?
    public let presentationGraph: PresentationGraphRevisionID?
    public let presentationMembership: PresentationMembershipRevisionID?
    public let subtitle: SubtitleRevisionID?
    public let surface: SurfaceRevisionID?
}

public struct ValidMediaTime: Codable, Hashable, Sendable {
    public let value: Int64
    public let timescale: Int32
}

public enum TimestampFault: String, Codable, Hashable, Sendable {
    case zeroTimescale, nonFiniteSource, overflow, discontinuity, unmappable
}

/// Canonical logical media time. Unknown and malformed values remain explicit.
public enum MediaTimestamp: Codable, Hashable, Sendable {
    case valid(ValidMediaTime)
    case unknown
    case invalid(TimestampFault)
}

public struct MediaDuration: Codable, Hashable, Sendable {
    public let microseconds: UInt64
}

/// Monotonic scheduler/virtual time supplied by an event.
public struct PlaybackInstant: Codable, Hashable, Comparable, Sendable {
    public let ticks: UInt64
}

public enum PlaybackAuthority: Codable, Hashable, Sendable {
    case application(ApplicationEpochID)
    case playback(
        sessionID: PlaybackSessionID,
        generation: PlaybackGenerationID,
        revisions: PlaybackRevisionSet
    )
}

/// Causality of one issued effect. A completion echoes this exact value.
public struct PlaybackEffectContext: Codable, Hashable, Sendable {
    public let authority: PlaybackAuthority
    public let operationID: PlaybackOperationID
    public let effectID: PlaybackEffectID
    public let streamID: PlaybackStreamID?
    public let trackID: PlaybackTrackID?
}

/// A parameterized acknowledgment identity. Component/revision prevent one audio
/// callback from satisfying a required video or new-membership acknowledgment.
public struct EffectResultToken: Codable, Hashable, Sendable {
    public let kind: EffectResultKind
    public let streamID: PlaybackStreamID?
    public let graphRevision: PresentationGraphRevisionID?
    public let membershipRevision: PresentationMembershipRevisionID?
    public let component: String?
}

public enum EffectResultRequirement: Codable, Hashable, Sendable {
    case exactly(EffectResultToken)
    case oneOf(Set<EffectResultToken>)
}

public enum EffectCompletionContract: Codable, Hashable, Sendable {
    /// Exactly one of these success/failure/cancelled terminal alternatives.
    case oneShot(terminals: Set<EffectResultToken>)
    /// Every requirement in phase N must be satisfied before phase N+1.
    case phased(phases: [[EffectResultRequirement]], terminal: Set<EffectResultToken>)
    /// Callback kinds may repeat only with an increasing callback sequence.
    /// The originating subscription stays outstanding until one terminal arrives.
    case subscription(
        id: PlaybackSubscriptionID,
        callbackKinds: Set<EffectResultToken>,
        terminals: Set<EffectResultToken>
    )
    case bestEffortMirror
}

public enum ExecutorKind: String, Codable, Hashable, Sendable {
    case input, videoDecode, audioDecode, presentation, subtitle
    case persistence, platform, diagnostics, resource
}

/// Immutable ownership history of a resource, independent of later effects using it.
public struct ResourceProvenance: Codable, Hashable, Sendable {
    public let authorityAtCreation: PlaybackAuthority
    public let createdByOperation: PlaybackOperationID
    public let createdByEffect: PlaybackEffectID
    /// Executor that physically stores and ultimately releases the resource.
    public let storageExecutor: ExecutorKind
}

public struct ResourceLeaseReference: Codable, Hashable, Sendable {
    public let key: ResourceLeaseKey
    public let provenance: ResourceProvenance
}

public enum LeaseDisposition: Codable, Hashable, Sendable {
    case retainedByProducer
    case transferred(to: ExecutorKind)
    case consumed
    case releaseRequested
    case physicallyReleased
}

public struct LeaseCustodyState: Codable, Hashable, Sendable {
    public var currentCustodian: ExecutorKind
    public var activeBorrows: Set<ResourceBorrowID>
    public var inFlightUseCount: Int
    public var releaseRequested: Bool
    public var physicalReleaseObserved: Bool
}

public struct LeaseTransfer: Codable, Hashable, Sendable {
    public let lease: ResourceLeaseReference
    public let disposition: LeaseDisposition
}

public struct PlaybackFailure: Codable, Equatable, Sendable {
    public enum Domain: String, Codable, Sendable {
        case input, demux, videoDecode, audioDecode, presentation
        case subtitle, persistence, platform, resource, invariant
    }
    public enum Recoverability: String, Codable, Sendable {
        case retryable, fallbackAvailable, fatal, cancelled
    }
    public enum Stage: String, Codable, Sendable {
        case open, probe, configure, read, seek, interrupt, reset, close
        case sendPacket, receiveFrame, convert, enqueue, flush, drain
        case render, persist, release, shutdown, callback
    }
    public let domain: Domain
    public let stage: Stage
    public let stableCode: String
    public let nativeCode: Int64?
    public let recoverability: Recoverability
    public let streamID: PlaybackStreamID?
    public let formatRevision: MediaFormatRevisionID?
    public let codecName: String?
    public let codecProfile: Int?
    public let hardwareWasConfigured: Bool
    public let hardwareOutputWasObserved: Bool
    public let consecutiveCount: Int
}
```

Every session-media effect has `PlaybackAuthority.playback` and therefore carries the exact session, generation, and relevant revision set. Pre-session preference/restore, application-lifetime presentation-graph/platform resources, and final shutdown work use application authority; a playback session borrows those application resources through revisioned leases. There are no unscoped async effects. `PlaybackEffectContext` adds the current operation/effect and relevant stream/track. A cancellation is a **new** effect context plus `targetEffectID`; it never reuses the cancelled effect’s ID.

Authority, causality, physical storage, and current custody are deliberately separate. A decoder lease created by one effect may be used by later decode/flush/close effects; those later completions echo their own effect context while the lease retains immutable `ResourceProvenance`. `storageExecutor` never changes and is the only place physical release occurs. A transfer changes `LeaseCustodyState.currentCustodian`; a borrow adds a child `ResourceBorrowID` without changing custody, and release waits for all borrows/in-flight C calls to settle. Every resource-bearing result includes a `LeaseDisposition`, so stale cleanup can distinguish returned, transferred, consumed, release-requested, and already-released resources without double release. `OutstandingEffectLedger` records the effect’s completion contract: one-shot effects accept exactly one of their success/failure/cancelled terminal tokens; phased effects satisfy ordered exact/one-of requirements keyed by stream/component/membership and complete on one declared terminal alternative; subscriptions accept only declared callback kinds with a monotonically increasing callback sequence and remain outstanding until a scoped `SubscriptionResultEvent` terminal acknowledgment arrives; best-effort diagnostic mirrors cannot feed policy and are considered settled at dispatch. Thus audio and video acknowledgments have distinct cardinality, and completed-versus-unavailable/timed-out alternatives are explicit rather than letting the first generic case finish an effect.

`PlaybackFailure` fields drive policy and distinguish configured-versus-observed VideoToolbox use, native error stage/code, format revision, and consecutive failure count. Localized messages, FFmpeg strings, `NSError` text, and locale-dependent labels are diagnostics/shell presentation outside the reducer.

ID exhaustion is an explicit fatal invariant rather than wrapping with `&+=`. Replay initial state contains the allocator state, so IDs are reproducible.

### 5.2 Machine state

Avoid a combinatorial “everything phase” enum. Keep orthogonal domain state under one atomically updated root:

```swift
public struct PlaybackCore: Sendable {
    public private(set) var state: PlaybackMachineState

    public init(initialState: PlaybackMachineState = .initial) {
        self.state = initialState
    }

    public mutating func update(_ event: PlaybackEvent) -> PlaybackTransition {
        // Validate scope, route to one owning reducer, reconcile cross-domain
        // intents, plan ordered effects, validate invariants, derive diagnostics.
    }
}

public struct PlaybackMachineState: Codable, Equatable, Sendable {
    public var lifecycle: LifecycleState
    public var active: ActivePlaybackState?
    public var playlist: PlaylistMachineState
    public var controls: PlaybackControlState
    public var platform: PlatformPlaybackState
    public var resources: ResourceLedger
    public var outstandingEffects: OutstandingEffectLedger
    public var diagnostics: PlaybackDiagnosticState
    public var ids: PlaybackIDAllocator
}

public struct ActivePlaybackState: Codable, Equatable, Sendable {
    public var sessionID: PlaybackSessionID
    public var source: MediaSourceIdentity
    public var generation: PlaybackGenerationID
    public var load: LoadingState
    public var tracks: TrackSelectionState
    public var transport: TransportState
    public var seek: SeekState
    public var demux: DemuxState
    public var video: VideoPipelineState
    public var audio: AudioPipelineState
    public var synchronization: SynchronizationState
    public var subtitles: SubtitleMachineState
    public var recovery: RecoveryState
    public var completion: CompletionState
    public var logicalPosition: MediaTimestamp
}
```

Recommended domain shapes:

```swift
public enum LifecycleState: Codable, Equatable, Sendable {
    case running
    case stopping(PlaybackOperationID)
    case shuttingDown(ShutdownState)
    case terminated(ShutdownSummary)
}

public enum LoadingPhase: Codable, Equatable, Sendable {
    case awaitingSurface
    case opening
    case probing(input: ResourceLeaseID)
    case configuring
    case prerolling
    case ready
    case failed(PlaybackFailure)
}

public struct TransportState: Codable, Equatable, Sendable {
    public enum Intent: String, Codable, Sendable { case playing, paused }
    public enum Actual: String, Codable, Sendable {
        case stopped, waitingForPreroll, paused, playing, buffering, draining
    }
    public var desired: Intent
    public var actual: Actual
    public var appliedClock: ClockState
}

public enum SeekState: Codable, Equatable, Sendable {
    case idle
    case pending(SeekTransaction)
    case invalidating(SeekTransaction, PendingBarrier)
    case demuxSeeking(SeekTransaction)
    case decoderPreroll(SeekTransaction, StreamReadiness)
    case presentationPreroll(SeekTransaction, StreamReadiness)
}

public struct SeekTransaction: Codable, Equatable, Sendable {
    public let operationID: PlaybackOperationID
    public let generation: PlaybackGenerationID
    public let requestedTarget: ValidMediaTime
    public let mode: SeekIntent.Mode       // relative is resolved before this point
    public let resumeIntent: TransportState.Intent
    public var actualLanding: MediaTimestamp
    public var supersededBy: PlaybackOperationID?
}

public enum StreamInputEnd: Codable, Equatable, Sendable {
    case active
    case cleanEOF
    case readFailure(PlaybackFailure)
    case disabled
}

public enum DrainProgress: Codable, Equatable, Sendable {
    case notApplicable
    case notRequested
    case requested(effectID: PlaybackEffectID)
    case completed
    case failed(PlaybackFailure)
}

public enum PresentationDrainEvidence: Codable, Equatable, Sendable {
    case notObserved
    case observing
    case proven(lastPresented: MediaTimestamp)
    case unconfirmed(DrainUncertainty)
    case failed(PlaybackFailure)
}

public enum SubmissionHorizon: Codable, Equatable, Sendable {
    case none
    case known(end: ValidMediaTime, count: Int)
    case unknown(count: Int, reason: TimestampFault?)
}

/// Independent facts tolerate duplicate and reordered callbacks.
public struct StreamCompletionState: Codable, Equatable, Sendable {
    public var input: StreamInputEnd
    public var decoder: DrainProgress
    public var converter: DrainProgress
    public var submission: SubmissionHorizon
    public var presentation: PresentationDrainEvidence
}

public struct BatchSlice: Codable, Equatable, Sendable {
    public let lease: LeaseTransfer
    public let itemRange: Range<Int>
}

public struct QueueOccupancyDelta: Codable, Equatable, Sendable {
    public let items: Int
    public let bytes: Int
    public let mediaMicroseconds: Int64
}

public enum BatchTerminal: Codable, Equatable, Sendable {
    case completed
    case backpressured
    case rejectedStale
    case failed(PlaybackFailure)
}

/// The input lease is atomically subdivided so partial work is replayable and releasable.
public struct BatchOutcome: Codable, Equatable, Sendable {
    public let originalInput: LeaseTransfer
    public let consumedPrefix: BatchSlice?
    public let retainedRemainder: BatchSlice?
    public let producedOutput: [BatchSlice]
    public let occupancyDelta: QueueOccupancyDelta
    public let terminal: BatchTerminal
}
```

The shutdown boundary is exact. `.shuttingDown` records final-checkpoint, cancellation, fence, subscription, executor-quiescence, and resource-release obligations and may emit only effects needed to settle them. A timeout remains `.shuttingDown` with explicit nonquiescent facts; any application force-exit is an AppKit product policy outside a false core completion. `.terminated` is reachable only after all registered callback subscriptions and executor work are quiescent and every logical release is acknowledged. It accepts no new resource ownership and emits no effects.

`PlaybackControlState` owns persistent desired volume, mute, playback rate, audio/subtitle delay, hardware-decode policy, and supported video adjustments; accepted runtime results record effective values separately where needed. `VideoPipelineState` and `AudioPipelineState` should each contain selected stream, decoder handle/revision, configured format revision, bounded queue summaries, committed-sample preroll progress, independent completion facts, and typed failure. Audio additionally owns converter/resampler drain and exact-seek trim state. `SynchronizationState` owns the core-selected required stream set and membership revision, committed-sample preroll, sink-capacity facts, requested versus observed clock/rate, accepted presentation observations, A/V error estimates, reset revision, and the policy result of drain evaluation. It does not own the Apple synchronizer.

EOF is not a forced linear enum: clean input end, read failure after valid data, decoder drain, optional converter drain, submission horizon, and presentation evidence can be reported twice or out of order and remain idempotent. `.none` submission is distinct from samples with unknown PTS. A true zero-frame required stream can become presentation `.notApplicable` only through an explicit no-output terminal fact; unknown-timestamp samples still require drain policy. A read failure may drain already accepted queued data for presentation, but its final item outcome is truncated/failed and can never consume the clean-completion or playlist-advance token. The demux executor reports its pump/input end, not the policy-required streams. Subtitle EOF does not gate A/V completion unless an explicitly approved policy adds it.

`DemuxState` owns input lease, catalog/timeline revision, read/seek state, packet queue summaries, and demux EOF. `TrackSelectionState` is the sole owner of requested/effective off/automatic/embedded/external subtitle selection and source persistence intent. `SubtitleMachineState` owns only the installed libass source identity and matching track revision, subtitle/overlay revisions, libass resource lease, pending source-ready/visible-clear/render operations, and last accepted overlay revision; it consumes track-selection and applied-delay intents without becoming a second selection or delay authority. The delay sign/unit convention is a documented protocol rule, while requested/effective delay values remain in `PlaybackControlState`. `RecoveryState` owns typed fault, lineage-keyed attempts/retry budget, selected recovery strategy, and operation phase. `PlatformPlaybackState` owns accepted application graph, surface/display revisions, PiP controller/borrow revision, audio-route revision, and only the platform facts that affect playback; AppKit objects remain executor-side.

Queue state uses all three relevant bounds, not just count:

```swift
public struct QueueSummary: Codable, Equatable, Sendable {
    public var items: Int
    public var bytes: Int
    public var mediaDuration: MediaDuration
    public var highWater: QueueWatermark
    public let limits: QueueLimits
    public var grantedCredits: Int
}
```

Long-lived native resources are individual logical leases. High-volume packet/frame output uses bounded `ResourceBatchLeaseID`s with counts and handle ranges, so state and replay remain bounded while release-request, physical-release, and acknowledgment conservation are testable. Under fair eventual delivery, the acknowledged ledger must reach zero before `.terminated`; a permanently dropped acknowledgment leaves an explicit nonquiescent timeout state rather than a false release proof. The runtime registry alone must never be the policy authority for whether shutdown is complete.

### 5.3 Derived UI state

`PlaybackUISnapshot` is an immutable, `Equatable`, `Sendable` projection, not mutable authority:

```swift
public struct PlaybackPlaylistItemSnapshot: Equatable, Sendable {
    public let item: FolderPlaylistItem
    public let progress: MediaPlaybackProgress?
}

public struct PlaybackCapabilitiesSnapshot: Equatable, Sendable {
    public let supported: Set<PlaybackCapability>
    public let deterministicRejections: [PlaybackCapability: CapabilityRejection]
}

public struct PlaybackUISnapshot: Equatable, Sendable {
    public let phase: PlaybackPhase
    public let source: MediaSource?
    public let sourceOrigin: MediaSourceOrigin?
    public let currentFolder: URL?
    public let playlist: [PlaybackPlaylistItemSnapshot] // item + persisted/live progress
    public let playlistIndex: Int?
    public let capabilities: PlaybackCapabilitiesSnapshot
    public let desiredPause: Bool
    public let currentTime: TimeInterval
    public let duration: TimeInterval?
    public let seekPreview: TimeInterval?
    public let videoAspectRatio: Double?
    public let bufferStatus: BufferStatus
    public let tracks: [MediaTrack]
    public let selectedAudioID: Int64?
    public let selectedSubtitleID: Int64?
    public let volume: Double
    public let isMuted: Bool
    public let playbackRate: Double
    public let audioDelay: TimeInterval
    public let subtitleDelay: TimeInterval
    public let audioOutputDevice: AudioOutputDevice?
    public let audioOutputDevices: [AudioOutputDevice]
    public let chapters: [Chapter]
    public let currentChapterID: Int64?
    public let videoOutput: VideoOutputStatus
    public let displayOutput: DisplayOutputStatus
    public let videoAdjustments: VideoAdjustmentState
    public let activeVideoFilters: [VideoFilterPreset]
    public let pictureInPicture: PictureInPictureState
    public let decoder: DecoderUISnapshot
    public let recentDiagnostics: [PlaybackDiagnosticSummary]
    public let userVisibleFailure: PlaybackFailurePresentation?
}
```

This is **semantic coverage**, not a promise that every proposed property name matches `PlaybackState`. During migration, a one-way adapter maps `currentTime` to current `position`, `playbackRate` to `playbackSpeed`, combined track values to current `audioTracks`/`subtitleTracks` and selected `MediaTrack?`, and optional duration to today’s nonoptional UI default. Before removing the adapter, either keep those established public names in `PlaybackViewStore` or migrate every caller with projection tests.

`PlaybackPlaylistItemSnapshot` carries the item plus `MediaPlaybackProgress`, combining persisted progress with the active item’s authoritative live position. It replaces `PlaylistSidebar`’s per-row call to `PlaybackCoordinator.playbackProgress(for:)`. `PlaybackCapabilitiesSnapshot` is a native value read by `SettingsView`, `PlayerCommands`, and views instead of calling `PlaybackCoordinator.capabilities`; it records supported versus deterministically rejected commands. The reducer compares stable track fields only and never evaluates `MediaTrack.displayName`, which reads ambient `Locale.current`; the shell formats locale-dependent labels from snapshot values. Window fullscreen, sidebar visibility, pointer/chrome state, panel state, and window frame remain shell state in `AppModel`; they are not playback-machine truth.

### 5.4 Explicitly excluded ownership

Neither `PlaybackCore` nor any reducer stores `AVFormatContext`, `AVCodecContext`, `AVPacket`, `AVFrame`, `CVPixelBuffer`, `CMSampleBuffer`, `AVSampleBufferRenderSynchronizer`, sample-buffer renderer objects, libass pointers/bitmaps, file handles, `DispatchQueue`, `Task`, timer, wall-clock object, view, window, layer, or coordinator reference. These appear only behind executor-owned registries addressed by stable handles.

## 6. Event catalog

Keep the existing word **Command** for user/product intent and **Event** for everything accepted by the machine. Do not introduce “Action” as a third synonym. `PlaybackEvent` is the one reducer input and wraps commands plus platform/runtime facts:

```swift
public struct PlaybackEventEnvelope: Codable, Equatable, Sendable {
    public let externalID: UInt64?
    public let observedAt: PlaybackInstant
    public let event: PlaybackEvent
}

public enum PlaybackEvent: Codable, Equatable, Sendable {
    case command(PlaybackCommand)
    case platform(PlatformPlaybackEvent)
    case scheduler(SchedulerEvent)
    case cancellation(CancellationResultEvent)
    case subscription(SubscriptionResultEvent)
    case playlist(PlaylistResultEvent)
    case input(InputResultEvent)
    case demux(DemuxResultEvent)
    case video(VideoDecoderResultEvent)
    case audio(AudioDecoderResultEvent)
    case presentation(PresentationResultEvent)
    case subtitle(SubtitleResultEvent)
    case persistence(PersistenceResultEvent)
    case platformResult(PlatformResultEvent)
    case resource(ResourceResultEvent)
}
```

### 6.1 Commands and external platform facts

| Group | Required cases and meaning |
|---|---|
| `PlaybackCommand` | Lifecycle/playlist: `.restoreRequested`, `.load(MediaLoadIntent)`, `.selectPlaylistItem(id:)`, `.playNext`, `.playPrevious`, `.play`, `.pause`, `.togglePause`, `.stop`, `.shutdown`, `.clearPlaybackHistory`. Seeking: `.seek(SeekIntent)` for relative/exact/preview and `.frameStep(direction:)`. Tracks/subtitles: `.selectAudioTrack(.automatic | .stream(id))`, `.selectSubtitleTrack(.off | .automatic | .embedded(id) | .external(id))`, `.loadExternalSubtitle(url:select:)`, `.setSubtitleEnabled`, `.selectAudioOutputDevice`. Controls: `.setVolume`, `.setMuted`, `.setPlaybackRate`, `.setAudioDelay`, `.setSubtitleDelay`, `.selectChapter`, `.setHardwareDecodingPolicy`, `.setVideoAspect`, `.setVideoCrop`, `.setVideoRotation`, `.setDeinterlace`, `.setVideoEqualizer`, `.resetVideoAdjustments`, `.setVideoFilter`, `.captureScreenshot`, `.setPictureInPicture`, `.dismissFailure`. Every current playback/product command is represented without ambiguous nil semantics. A native-unsupported command produces a deterministic capability rejection; it never bypasses the core. Implementing currently unsupported speed/audio-delay/output/filter/screenshot behavior is separate parity work unless the owner makes it a legacy-removal gate. |
| `PlatformPlaybackEvent` | `.applicationLaunched`, `.surfaceAttached(surfaceID,surfaceRevision,display)`, `.surfaceDetached(surfaceID,surfaceRevision)`, `.willSleep(lifecycleSequence)`, `.didWake(lifecycleSequence)`, `.displayChanged(surfaceID,displayRevision,display)`, `.fullscreenChanged(surfaceID,surfaceRevision,value)`, `.audioRouteChanged(routeRevision,value)`, `.pictureInPictureChanged(controllerID,borrowRevision,state)`, `.terminationRequested`. Every object-originated callback carries its object/revision identity so an old host/controller cannot detach or reconfigure its replacement. Fullscreen remains shell-owned; the event is informational unless presentation policy needs it. |
| `SchedulerEvent` | Unsolicited `.tick(PlaybackInstant)` carries an external sequence. Effect-created `.deadlineReached(context:kind:scheduledFor:)`, `.checkpointDue(context)`, and `.previewDebounceFired(context)` echo their scheduler effect context and are one-shot terminal results. Tests supply virtual ticks; production scheduler supplies monotonic ticks. |

### 6.2 Runtime result events

Every result below carries the originating `PlaybackEffectContext` (the case label uses `context`). Every resource-bearing field is a `LeaseTransfer`, not a bare handle, so stale processing knows its immutable provenance and current disposition.

| Result enum | Required cases |
|---|---|
| `PlaylistResultEvent` | `.discovered(context,collection,items)`, `.discoveryFailed(context,failure)`, `.discoveryCancelled(context)`. The context carries the scan operation/effect ID, replacing `folderScanGeneration: UUID`; the core accepts or rejects the result and owns cursor/completion semantics. |
| `CancellationResultEvent` | `.interruptRequested(cancelContext,targetEffectID)`, `.targetNotActive(cancelContext,targetEffectID,targetTerminalDisposition)`, `.requestFailed(cancelContext,targetEffectID,failure)`. This closes the **cancellation effect only**. If target A already returned normally, `targetNotActive` is truthful. If a signal is installed, `interruptRequested` is terminal for the cancel request while target A remains outstanding until its own subsystem result arrives. |
| `SubscriptionResultEvent` | `.cancelled(originalContext,subscriptionID,lastCallbackSequence)`, `.ended(originalContext,subscriptionID,lastCallbackSequence,reason)`, `.failed(originalContext,subscriptionID,lastCallbackSequence,failure)`. These are the only terminals for the **original subscription effect**. A separate cancel request settles independently; shutdown cannot count the subscription quiescent until its original context reports a terminal and later callbacks are fenced/rejected. |
| `InputResultEvent` | `.opened(context,inputLease,provisionalTimeline)`, `.probed(context,inputLease,catalog,timeline,decoderConfigurations)`, `.cancelled(originalContext,cancellationOperationID)`, `.openFailed(context,failure)`, `.probeFailed(context,inputLease,failure)`. The original open/probe effect closes only on its own normal/failed/cancelled terminal result, independently of the cancellation effect. Decoder configurations are owned copies/immutable value leases, never pointers borrowed from `AVFormatContext`. Physical input close is reported only as `ResourceResultEvent.releaseCompleted`/`.releaseFailed`. |
| `DemuxResultEvent` | `.packetBatchesRead(context,perStreamBatches,occupancy)`, `.readWouldBlock(context)`, `.flushed(context,inputRevision)`, `.seekCompleted(context,actualLanding)`, `.seekFailed(context,failure)`, `.inputEnded(context,pumpID)`, `.catalogChanged(context,catalogRevision,catalog)`, `.failed(context,failure)`, `.cancelled(context)`. Demux reports input/pump EOF, not the policy-required stream set. Packet descriptors contain stable handles, `PlaybackStreamID`, timestamp/duration/keyframe/byte metadata, never `AVPacket`. Mixed input is split into per-stream child leases before separate consumers; parent release waits for every child disposition. |
| `VideoDecoderResultEvent` | `.configured(context,decoderLease,format,mode)`, `.batchProgress(context,outcome,frames)`, `.flushed(context)`, `.drained(context)`, `.formatObserved(context,descriptor,fingerprint,heldFrameLease)`, `.failed(context,PlaybackFailure)`. The executor reports an observed descriptor/fingerprint but never invents a core revision; the core allocates `MediaFormatRevisionID`, fences old output, and commands reconfiguration before the held/new-format frame can continue. `BatchOutcome` records consumed prefix, separately leased remainder/output, occupancy, and optional failure. Frame descriptors include handle, timestamps, duration, authorized format revision, and display metadata, never `CVPixelBuffer`. Physical decoder close is a resource release result only. |
| `AudioDecoderResultEvent` | `.configured(context,decoderLease,format)`, `.converterConfigured(context,converterLease,formatRevision,format)`, `.batchProgress(context,outcome,frames)`, `.flushed(context)`, `.decoderDrained(context)`, `.converterDrained(context)`, `.formatObserved(context,descriptor,fingerprint,heldFrameLease)`, `.failed(context,PlaybackFailure)`. Decoder and lazily configured converter are distinct. The core allocates the media-format revision after observation and commands converter recreation; partial output before failure is retained in `BatchOutcome`. Audio descriptors include sample range, authorized format revision, and exact-seek trim metadata, never PCM bytes. Decoder/converter close is reported only by resource release. |
| `PresentationResultEvent` | `.graphCreated(applicationContext,graphRevision,graphLease)`, `.sessionSinksConfigured(context,graphBorrow,sinkLeases,membershipRevision)`, `.creationFailed(context,failure)`, `.fenceInstalled(context,presentationRevision)`, `.flushRequested(context,kind)`, `.flushCompleted(context,kind)`, `.flushEvidenceUnavailable(context,kind)`, `.synchronizerReset(context,clock)`, `.sinkCanAcceptData(context,kind,callbackSequence)`, `.enqueueProgress(context,outcome,submittedRange)`, `.firstFrameDisplayed(context,position)` only when proven, `.clockSample(context,ClockSample)`, `.statusObserved(context,RendererObservation,callbackSequence)`, `.rateRequestAccepted(context,requestedRate)`, `.rateObserved(context,effectiveRate,clock,callbackSequence)`, `.audioGainApplied(context,volume,muted)`, `.audioGainFailed(context,failure)`, `.platformDrainCompleted(context,kind,lastPresentedTime)` only for a hard API fact, `.rendererFailed(context,kind,membershipRevision,callbackSequence,failure)`, `.surfaceUnavailable(context,surfaceID,surfaceRevision)`. `RendererObservation` includes status/error and `requiresFlushToResumeDecoding`. The fence/flush/reset result tokens form the ordered, component-keyed phased contract of one barrier effect. Backpressure/status/rate/error subscriptions use callback sequences. `sinkCanAcceptData` is not preroll; only accepted sample commits plus configured current-generation thresholds establish preroll. A setter return is not observed playback rate. `SynchronizationReducer` applies drain, rate, and recovery policy. |
| `SubtitleResultEvent` | `.sourceLoaded(context,subtitleLease,trackRevision)`, `.sourceLoadFailed(context,failure)`, `.packetBatchProgress(context,outcome)`, `.sourceStateReady(context,revision,embeddedResetOrExternalRetained)`, `.frameRendered(context,renderLease,geometry)`, `.overlayCommitted(context,renderLease)`, `.overlayRejected(context,renderLease,.staleRevision)`, `.visibleOverlayCleared(context,revision)`, `.failed(context,failure)`. Source-specific libass readiness and visible main-actor clear are independent acknowledgments; new commits require both, while clear is never blocked behind libass work. Physical subtitle close is a resource release result only. |
| `PersistenceResultEvent` | `.restoreLoaded(context,record?)`, `.restoreFailed(context,failure)`, `.preferencesLoaded(context,preferences)`, `.readFailed(context,key,failure)`, `.writeCompleted(context,key,version)`, `.writeFailed(context,key,failure)`. Progress/checkpoint/completion/preference writes use the general keyed completion contract. Pre-session work uses application authority. Calendar timestamps remain executor-owned metadata. |
| `PlatformResultEvent` | `.surfaceCreated(context,surfaceID,surfaceLease,revision)`, `.surfaceDetached(context,surfaceID,surfaceRevision,surfaceLease)`, `.displayApplied(context,surfaceID,displayRevision)`, `.pictureInPictureApplied(context,controllerID,borrowRevision,state)`, `.nowPlayingPublished(context,revision)`, `.idleSleepAssertionApplied(context,active)`, `.operationFailed(context,objectIdentity,kind,failure)`. `surfaceDetached` acknowledges graph/UI detachment and returns custody; it is not physical destruction. Borrowing the presentation layer is represented by leases and every callback/result repeats the originating object identity. Physical surface release still has only the generic resource acknowledgment. |
| `ResourceResultEvent` | `.releaseCompleted(context,leaseWithPhysicallyReleasedDisposition)`, `.releaseFailed(context,lease,failure)`, `.executorQuiesced(context,executorKind)`, `.runtimeShutdownCompleted(context,summary)`, `.runtimeShutdownTimedOut(context,outstandingLeases)`. Emitting `ResourceEffect.release` records the logical request; the immutable storage executor performs the physical release; delivery of `.releaseCompleted` is the core’s single observed acknowledgment. A physically completed but deliberately dropped result remains an explicit timeout/nonquiescent model case, not a second handshake. |

Unsolicited platform events have an external sequence/tick rather than an effect context. All async work initiated by the core has a full context. A mismatched or duplicate result is recorded as rejected; its `LeaseDisposition` determines whether cleanup is needed. A stale event whose resource was already consumed or physically released must not cause another release.

Track replacement deliberately has no synthetic runtime-level “prepared” or “committed” event. The core derives those transaction states atomically from the scoped decoder, presentation, subtitle, fence, and resource results above. This prevents a hidden track orchestrator in the runtime from becoming a second policy owner.

## 7. Effect catalog

`PlaybackEffect` is a value description of work, not a closure and not an executor reference. Effects carry stable error/result contracts and the scope allocated by the core.

```swift
public enum PlaybackEffect: Codable, Equatable, Sendable {
    case playlist(PlaylistEffect)
    case input(InputEffect)
    case demux(DemuxEffect)
    case video(VideoDecoderEffect)
    case audio(AudioDecoderEffect)
    case presentation(PresentationEffect)
    case subtitle(SubtitleEffect)
    case persistence(PersistenceEffect)
    case platform(PlatformEffect)
    case diagnostics(DiagnosticsEffect)
    case scheduler(SchedulerEffect)
    case resource(ResourceEffect)
}
```

### 7.1 Playlist, input, and demux

| Effect | Required payload and result |
|---|---|
| `PlaylistEffect.discover` / `.cancelDiscovery` | New context, folder/source value, deterministic sort/match options, or target effect ID. The executor performs filesystem enumeration/matching and returns exactly one discovered/failed/cancelled terminal result. The core alone accepts the collection/cursor. |
| `InputEffect.open` | Context, normalized source descriptor, interrupt token/lease. The executor allocates `AVFormatContext` and installs its atomic interrupt callback before `avformat_open_input`. Returns exactly one opened/failed/cancelled terminal result. |
| `InputEffect.probe` | New context, input lease, and probe limits. Returns exactly one probed/failed/cancelled terminal result with owned decoder configurations. Open and probe are separate effect IDs so the first fact cannot accidentally complete both phases. |
| `InputEffect.cancelOpen` / `.cancelProbe`; `DemuxEffect.cancelRead` / `.cancelSeek` | A new cancellation context, `targetEffectID`, and reason. The AVIO callback interrupts only while its atomic active-C-call token equals that target; every open/probe/read/seek call installs and clears/advances the token at its boundary. The cancel effect returns exactly one `interruptRequested`, `targetNotActive`, or failed terminal result. Independently, the original target effect returns its own normal/failed/cancelled terminal result. Both ledger entries settle; a late cancellation for call A cannot abort call B. |
| `InputEffect.close` | Context and input lease. Close runs on that input’s storage queue and returns only generic `ResourceResultEvent.releaseCompleted` or `.releaseFailed`; there is no second input-close acknowledgment. |
| `DemuxEffect.readPacketBatch` | Context, input lease, bounded item/byte/media-duration budget, and per-stream output batch leases. Returns descriptors/occupancy, would-block, EOF, or failure. |
| `DemuxEffect.seek` | Context, input lease, logical and demux target, flags/policy. Returns actual landing/failure; “exact” remains a core decode-forward policy rather than pretending FFmpeg lands exactly. |
| `DemuxEffect.flush` | Context/input lease after seek/revision. Returns acknowledgment. |

### 7.2 Decode and conversion

| Effect | Required payload and result |
|---|---|
| `VideoDecoderEffect.configure` | Context, **owned decoder-configuration lease** copied by the input executor, selected stream, decoder revision, requested hardware policy. Returns decoder lease and actual mode or typed failure. |
| `VideoDecoderEffect.decodeBatch` | Context, decoder lease/revision, per-stream packet batch lease, bounded output batch lease. Returns `BatchOutcome` plus frame descriptors, including frames produced before a later packet failure and a separately leased unconsumed remainder. |
| `VideoDecoderEffect.reconfigureFormat` | Context with a **core-allocated** media-format revision, observed descriptor/fingerprint, and held-frame lease. Rebuilds only format-dependent decoder/conversion/presentation metadata and returns an acknowledgment before new-format output is granted. |
| `VideoDecoderEffect.flush` / `.drain` | Scoped command with explicit acknowledgment. Drain remains distinct from close. |
| `VideoDecoderEffect.recreate` | Core-selected mode/revision after a typed recovery decision. It does not decide fallback itself. |
| `AudioDecoderEffect.configure` | Context, owned decoder-configuration lease, selected stream, decoder revision, requested output format. Converter readiness is a later result because current `SwrContext` creation is lazy. |
| `AudioDecoderEffect.decodeBatch` | Scoped packet batch to opaque PCM frame batch; result includes `BatchOutcome`, sample/timestamp summary, partial output, and retained remainder. |
| `AudioDecoderEffect.reconfigureConverter` | Context with a core-allocated media-format revision, observed audio descriptor/fingerprint, and held-frame lease. Drains/releases the old converter as policy directs, creates the new `SwrContext`, and acknowledges before conversion resumes. |
| `AudioDecoderEffect.trim` | Optional executor mechanism for the core-authorized exact-seek sample boundary. |
| `AudioDecoderEffect.flush`, `.drainDecoder`, `.drainConverter`, `.recreate` | Separate acknowledgments so EOF and recovery cannot skip delayed codec or resampler output. |

### 7.3 Presentation and synchronization

| Effect | Required payload and result |
|---|---|
| `PresentationEffect.createGraph` / `.replaceGraph` | **Application-authority** context and core-allocated graph revision. Creates the synchronizer/display-layer graph and returns its storage lease; it does not choose a media session or renderer membership. Video renderer recreation requires `.replaceGraph` because `SampleBufferVideoPresenter` uses the renderer owned by that exact `AVSampleBufferDisplayLayer`; it is not modeled as swapping a renderer behind a stable layer. |
| `PresentationEffect.configureSessionSinks` | Playback context, borrowed graph lease, required A/V streams, and membership revision. Creates/attaches only required renderers, removes obsolete membership behind a fence, and returns sink leases. A/V, video-only, audio-only, and no-output replacement are explicit; an absent renderer cannot remain a clock/preroll/EOF participant. |
| `PresentationEffect.installFenceAndRequestFlush` | One nonblocking serialized commit-barrier operation: install accepted authority/revisions, order renderer flush requests and synchronizer rate-zero/reset against sample commits, and carry `DisplayedImagePolicy.retainCurrentSameMediaFrame` or `.removeImmediately`. Same-media seek retention is allowed only as an approved UX policy; replacement, stop, and shutdown always remove old pixels, including PiP. Returns the declared phased fence/flush/reset facts. Actual per-renderer flush completion or unavailable evidence arrives separately. |
| `PresentationEffect.enqueueVideoBatch` / `.enqueueAudioBatch` | Context, matching sink/membership revision, frame batch lease. Perform no readiness busy-wait on the commit gate; use callbacks/bounded enqueue quanta. Recheck the fence at each item commit and return `BatchOutcome` with consumed prefix, retained remainder, submitted range, and optional failure/stale terminal state. |
| `PresentationEffect.applyRate` | Context, desired rate and anchor media time. Returns request-accepted only; an independently sequenced synchronizer observation reports effective rate/clock. It is emitted only after core preroll policy passes. |
| `PresentationEffect.pause` | Scoped rate-zero request; paused transport becomes actual only after a matching observed-rate/clock event. It preempts any pending nonzero-rate request through the same fence. |
| `PresentationEffect.applyAudioGain` | Context plus desired volume/mute revision. Applies gain to the audio renderer and returns typed applied/failed values; `ControlReducer` keeps desired and effective state distinct. |
| `PresentationEffect.sampleClock` | Returns explicit synchronizer/media/host clock facts; core never reads a clock itself. |
| `PresentationEffect.observeDrain` | Context, explicit `SubmissionHorizon`, required renderer, and membership revision. Returns raw clock/status/backpressure/automatic-flush/`requiresFlushToResumeDecoding` observations or a hard platform completion fact. The executor does not apply EOF tolerance or timeout policy. |
| `PresentationEffect.reset` / `.release` | Explicit scoped acknowledgment and resource release. |

The commit fence has a strict ordering guarantee. Every video/audio item commit and every rate request uses the same sequencer as fence installation and flush/reset **requests**. If an old commit wins first, the ordered flush request follows it. If fence installation wins first, the old commit is rejected and its `BatchOutcome` returns the remainder. Actual asynchronous flush completion is not faked as part of that atomic step; the core waits for required observable acknowledgments or explicit unavailable/timeout policy before progressing. A matching nonzero rate request is not `.playing` until a later effective-rate/clock observation agrees. The same rule applies across file replacement, not only in-session seek.

`requiresFlushToResumeDecoding` is a raw Apple renderer fact, not a generic buffering label. Initial policy is: raise a scoped presentation fault, install a current fence, perform at most one flush/reprime of the existing sink for that revision, and re-enter preroll. On recurrence/failed flush, video recovery either replaces the entire presentation graph/display-layer revision, reconfigures session membership, atomically rebinds the surface and PiP content source/controller on the main actor, then releases the old graph after borrows settle—or enters an owner-approved terminal/degraded state. It must not claim to recreate the `sampleBufferRenderer` behind a stable borrowed layer. Audio-only sink recreation may remain within a graph if Apple ownership permits. An old revision’s observation or flush completion cannot consume the new revision’s recovery budget.

### 7.4 Subtitles

| Effect | Required payload and result |
|---|---|
| `SubtitleEffect.createTrack` | Context, selected embedded/external source, subtitle revision, script metadata, bounded font attachment handles. Per-session `ASS_Library` is the simplest truthful lifetime; a shared cache requires an explicit rebuildable library generation because `ass_add_font` retains font data internally. |
| `SubtitleEffect.loadExternalFile` | Scoped asynchronous file read/parse with approved file-byte and cue/event limits; no `Data(contentsOf:)` on the main actor. |
| `SubtitleEffect.processPacketBatch` | Context/revision plus packet handles; returns a partial `BatchOutcome` so a failure cannot duplicate or leak processed packets. |
| `SubtitleEffect.render` | Context/revision and explicit logical playback time/viewport; returns an opaque render lease and geometry subject to region-count and total pixel-byte limits. |
| `SubtitleEffect.installOverlayFenceAndClear` | Control-priority main-actor endpoint: install the new revision and clear visible regions immediately, without waiting for libass parse/render/font work. Returns `visibleOverlayCleared`. |
| `SubtitleEffect.invalidateSourceState` | Separate subtitle-worker effect. For streamed embedded subtitles, reset events/caches and repopulate after seek. For a fully loaded external ASS/SRT source, retain or deterministically reload the full cue set rather than erasing it. New overlay commits wait for both visible-clear and source-ready acknowledgments. |
| `SubtitleEffect.commitOverlay` | Main-actor final commit that rechecks session/generation/subtitle/surface revision immediately before touching `SubtitleOverlayView`. |
| `SubtitleEffect.release` | Requests release of libass track/renderer/font leases; physical completion returns only generic `ResourceResultEvent.releaseCompleted`/`.releaseFailed`. |

### 7.5 Persistence, platform, diagnostics, scheduler, and resources

| Group | Effects |
|---|---|
| Persistence | Read restore/preferences; persist progress, completion token, last-opened media, playlist cursor, volume/mute/rate and shell preferences; clear history. Payloads are value snapshots. The executor supplies filesystem and calendar metadata. |
| Platform | Attach/detach/configure a specific surface ID/revision; apply a specific display revision; start/stop a specific PiP controller/borrow revision; publish/clear Now Playing; acquire/release idle-sleep assertion; request fullscreen/window work only when explicitly delegated by the shell. AppKit execution is `@MainActor`, and every result/callback repeats the object identity. |
| Diagnostics | Append structured journal record, emit signpost/log/counter, write failure replay, report an invariant in debug/test. Human-readable localized strings are derived here, not reducer policy inputs. These are explicitly `bestEffortMirror` contracts: they carry context/journal sequence, settle at dispatch, and can never return a policy event. Failures go to an out-of-band emergency log. |
| Scheduler | Schedule/cancel preview debounce, timeout, checkpoint, clock sample, or drain observation. A scheduled one-shot completion is a context-bearing `SchedulerEvent`; periodic sampling is a subscription with callback sequence and explicit cancellation. |
| Resources | Release one long-lived or batch lease; cancel an effect; cancel a callback subscription; quiesce an executor; begin/finalize runtime shutdown. Cancelling a subscription first settles the cancel request, then requires `SubscriptionResultEvent` for the original subscription context before quiescence. Cleanup effects are explicitly marked so `.shuttingDown` validation can allow only them; `.terminated` allows no effect. |

Every authoritative effect issued by the planner is registered in `OutstandingEffectLedger` with its completion contract before `update` returns. Acceptance consumes a `(effectID, resultToken)` at most once for one-shot/phased work; the effect closes only on one declared terminal alternative after every ordered exact/one-of requirement is satisfied. Subscriptions accept strictly increasing callback sequences until a declared `SubscriptionResultEvent` terminal closes the original context; a cancellation request alone never closes it. Best-effort diagnostic mirrors settle at dispatch and are excluded from policy liveness. Conflicting effects cannot be silently dispatched.

## 8. Reducer ownership map

Do not broadcast every event to every reducer and do not build a single `playloop.c`-sized switch. Route each event to one primary owner. That reducer mutates only its owned state slice and emits typed **internal intents**. A small root coordinator handles the limited set of cross-domain atomic transactions; an effect planner turns non-conflicting intents into scoped, ordered effects.

| Reducer | State owned | Primary events | Intents emitted |
|---|---|---|---|
| `SessionReducer` | Active media/session ID, source identity, desired transport default, per-item completion token. | Load/stop commands, accepted load failure/final EOF, replacement. | Begin/release session, begin load, persist completion, request playlist advance once, fail/stop. |
| `PlaylistReducer` | Accepted collection/items, cursor, discovery operation, selection/restart semantics. | Playlist discovery results; select/next/previous commands; advancement intent from final EOF. | Discover/cancel, select/reload/resume, advance cursor, request load. |
| `LoadingReducer` | Open/probe/configuration phases, catalog/timeline, required configuration acknowledgments. | Surface availability, input opened/probed/failed, decoder/subtitle configuration. | Open/cancel input, configure required pipelines, enter preroll. |
| `SeekReducer` | The sole authoritative `SeekTransaction`, preview target/deadline, supersession, landing/floors, phase acknowledgments. | Relative/exact/preview command, tick, flush/seek/preroll result, EOF/failure during seek. | Begin generation barrier, cancel prior operation, demux seek, grant preroll, finish/fail. |
| `DemuxReducer` | Input/read revision, packet credits/queue summaries, timeline mapping, demux EOF and failure. | Packet batch, would-block, seek result, EOF, catalog change. | Read/stop-read/release packets, decoder work, demux drain/failure. |
| `VideoDecoderReducer` | Selected video stream, decoder lease/revision/mode, queue summary, format, readiness, drain. | Video configured/output/format/drain/failure. | Decode/flush/drain/release, presentation enqueue intent, recovery fault. |
| `AudioReducer` | Selected audio stream, decoder/converter leases/revisions, queue summary, exact trim, readiness, decoder/converter drain. | Audio configured/output/format/drain/failure. | Decode/trim/flush/drain/release, audio enqueue intent, recovery fault. |
| `SynchronizationReducer` | Required streams, sink membership/presentation revision, committed-sample preroll, submission/presentation horizons, requested/effective clock rate, actual transport, buffering/A-V bounds, presentation drain. | Enqueue progress, sink-capacity, clock/rate, flush/drain/renderer events; play/pause intent after session routing. | Invalidate sink, enqueue, sample clock, request/pause rate, observe drain, buffering/recovery facts. |
| `TrackSelectionReducer` | Requested/effective audio track and requested/effective subtitle mode (`off`/`automatic`/embedded/external), source-persistence intent, track transaction, prepared resources, commit/rollback and track revision. | Track/enable/external-source commands plus scoped decoder/subtitle/presentation/resource component facts. | Prepare, commit, rollback, install/remove subtitle-source intent, invalidate generation/subtitle, release old resources. Prepared/committed/rolled-back are internal derived states, not executor policy events. |
| `SubtitleReducer` | Installed libass source identity plus matching track revision, subtitle and overlay revisions, libass readiness, pending clear/render, cue/overlay acceptance. | Internal source-install/remove and applied-delay intents; packet/render/commit/clear/failure; invalidation intents from seek/replacement/track. | Load/process/render, invalidate/reset/clear, overlay commit/release, and source-ready/failure facts back to the track transaction. It never chooses the effective track or owns the delay preference. |
| `RecoveryReducer` | Typed fault, retry budget, strategy, recovery operation/phase, last stable logical position. | Demux/decoder/presenter/subtitle failures and recovery completions. | Advance generation, cancel/invalidate, recreate software decoder, repreroll, degrade or fail. |
| `ControlReducer` | Desired/effective volume, mute, rate preference, audio/subtitle delays, hardware policy, chapter, output route, and video adjustments/capability rejection. | Control commands and typed presentation/platform/backend application results. | Apply supported gain/rate/delay/output/video changes, send applied subtitle-delay intent to `SubtitleReducer`, persist preferences, reject unsupported native capability. Transport play/pause still routes to synchronization. |
| `PersistenceReducer` | Restore/read/write operation versions, checkpoint due/pending state, last accepted persistence result. | Persistence and checkpoint scheduler results; persistence-affecting internal intents. | Read/write/cancel persistence work and report nonfatal/fatal policy facts to Session/Lifecycle. It never owns resume or playlist policy. |
| `ResourceReducer` | Logical lease custody/borrows/release state and executor/subscription quiescence. | Resource results and lease-bearing stale dispositions. | Release/cancel/quiesce effects and a quiescence fact to Lifecycle. It never owns `OutstandingEffectLedger` or decides shutdown policy. Effect registration/result-token consumption is root Validate/Plan infrastructure. |
| `LifecycleReducer` | Application presentation-graph lease/revision/replacement, sleep/wake transaction, surface/display/PiP availability, shutdown phase, quiescence requirements. | Application-authority graph creation/failure/release; platform sleep/wake/surface/display/PiP/termination; quiescence/timeout facts. | Create/replace/release graph, coordinate platform rebind, checkpoint, pause/repreroll, cancel operations, shutdown executors, terminalize. Playback-authority sink membership remains `SynchronizationReducer` state. |

Playlist item metadata can continue to reuse `FolderPlaylist`/`FolderPlaylistItem` values. Folder enumeration and sorting remain outside the core; a discovered playlist arrives as a value event. The core owns only the accepted list/cursor and completion token needed for deterministic advancement.

“One primary owner” applies to the raw event. The mechanism reducer consumes it and emits a typed internal fact to any transaction coordinator **within the same synchronous update**:

- decoder configuration/output first updates `VideoDecoderReducer` or `AudioReducer`; a `.pipelineConfigured` intent then advances `LoadingReducer` or `TrackSelectionReducer`;
- presentation fence/flush/sink-capacity/commit facts first update `SynchronizationReducer`; a `.seekBarrierProgressed` intent then advances `SeekReducer`;
- demux EOF/failure first updates `DemuxReducer`; it becomes provisional input-end for an active seek or a completion fact for `SessionReducer`;
- a subsystem failure first records the mechanism’s state, then emits `.faultRaised` to `RecoveryReducer`;
- playlist discovery/selection first updates `PlaylistReducer`; a `.loadSelectedItem` intent then enters `SessionReducer`, while final EOF consumes the session completion token before an `.advanceOnce` intent moves the cursor in the same root transaction;
- persistence raw results first update `PersistenceReducer`; accepted restore/checkpoint facts then inform `SessionReducer` or `LifecycleReducer` without granting persistence policy authority;
- resource results first update `ResourceReducer`; only its derived quiescence fact can satisfy `LifecycleReducer` termination prerequisites;
- audio-gain and other nontransport control application results first update `ControlReducer`. Presentation `rateRequestAccepted`/`rateObserved` always route first to `SynchronizationReducer`; a user speed preference in `ControlReducer` reaches it only as an internal desired-rate intent;
- subtitle track/enable/external-source commands first update `TrackSelectionReducer`; its internal install/remove intent drives `SubtitleReducer`, whose source-ready/failure fact returns to the same track transaction. Subtitle-delay commands and application results first update `ControlReducer`; `SubtitleReducer` receives only the accepted applied-delay intent;
- application-authority graph and lifecycle/platform operation results first update `LifecycleReducer`; accepted graph/surface facts may then produce a playback-authority sink-configuration intent for `SynchronizationReducer`.

This routing prevents two reducers from independently consuming the same completion while keeping cross-domain changes atomic.

### 8.1 Cross-domain coordination

Reducers do not directly call each other and do not emit final runtime work. They return values such as:

```swift
enum PlaybackIntent {
    case replaceSession(MediaLoadIntent)
    case invalidateGeneration(reason: GenerationChangeReason)
    case configurePipelines(MediaCatalog)
    case beginPreroll(PlaybackOperationID)
    case recover(PlaybackFailure)
    case finalizeEOF(CompletionToken)
    case beginShutdown
    case issue(EffectRequest)
}
```

One root reduction proceeds in fixed phases:

1. **Validate:** classify the event as accepted, duplicate, stale, invalid, or terminally ignored. Before termination, returned leases from non-accepted events are retained only long enough to emit cleanup. After `.terminated`, the runtime tombstone described in Section 9 settles any hostile late lease before mailbox delivery, so the core returns `.ignoredAfterTermination` with no effects.
2. **Route:** send the event to one owning reducer.
3. **Coordinate:** apply declared cross-domain intents atomically to the root state.
4. **Reconcile:** derive readiness/EOF/recovery/lifecycle transitions until no new immediate state-only intent exists; cap iterations and fail an invariant on a cycle.
5. **Plan:** allocate operation/effect IDs where needed, register leases/outstanding effects, reject conflicting effect keys, and return effects in deterministic order.
6. **Validate and project:** run invariants and derive the UI snapshot/diagnostic transition record.

The recommended API makes event disposition explicit for replay:

```swift
public enum EventDisposition: Codable, Equatable, Sendable {
    case accepted
    case duplicate(effectID: PlaybackEffectID)
    case stale(StaleEventReason)
    case invalid(InvalidEventReason)
    case ignoredAfterTermination
}

public struct PlaybackTransition: Codable, Equatable, Sendable {
    public let disposition: EventDisposition
    public let effects: [PlaybackEffect]
}

public mutating func update(_ event: PlaybackEvent) -> PlaybackTransition
```

This is a small, useful deviation from the conceptual `[PlaybackEffect]` signature. A stale result can be reported as stale while still producing resource cleanup effects. If a call site only needs effects, it uses `transition.effects`.

### 8.2 Transitions that must be atomic

The following are one synchronous root-state mutation, even though their runtime work completes in phases:

- **File replacement:** allocate new session and generation, revoke old session authority, create old-resource release obligations, reset completion token and selected state, then emit cancellation/commit-fence effects.
- **Seek:** supersede the old seek, allocate operation and new generation, reset all current-generation readiness/EOF/subtitle state, revoke sink commits, and preserve resume intent.
- **Track change:** create requested/effective distinction, new track/decoder revisions and generation, retain the old playable leases until prepared replacement commits or rolls back.
- **Recovery:** classify a typed fault, consume retry budget, allocate recovery operation/generation, invalidate output, and choose strategy. A decoder cannot do this itself.
- **Stop/shutdown:** revoke non-cleanup authority and enumerate release/cancellation obligations before any callback can be accepted as normal work.
- **Final EOF:** atomically consume the per-item completion token and advance playlist at most once only after every required current-generation drain is final.

### 8.3 Effect ordering and conflict prevention

Use exclusive effect keys such as `.input`, `.demuxControl`, `.videoDecoder(revision)`, `.audioDecoder(revision)`, `.presentationSink(revision)`, `.subtitleTrack(revision)`, `.persistenceRecord(key)`, and `.platformResource(kind)`. Two exclusive effects for the same key in one transition are an invariant failure, not “last wins.” Bounded data-pump grants are non-exclusive but consume explicit credits.

For effects emitted in one transition, use this stable submission order:

1. revoke/cancel and install commit fences;
2. pause/reset/flush;
3. release invalidated batch resources;
4. close obsolete long-lived resources;
5. open/configure/seek;
6. grant read/decode work;
7. enqueue/render;
8. apply rate/start;
9. persistence/platform publication;
10. diagnostics.

Array order is never used as a substitute for a completion dependency. For example, seek advances generation and emits presentation invalidation/cancel-read first; only after matching acknowledgments does it emit FFmpeg seek and decoder flush; only after those results does it grant new reads and enter preroll.

## 9. Runtime and threading model

### 9.1 Executor boundaries

| Executor | Native ownership | Serialization | Allowed decisions |
|---|---|---|---|
| `FFmpegInputExecutor` | Adapted `FFmpegDemuxer`, executor-local `AVFormatContext`, AVIO interrupt token, owned decoder-configuration copies, per-stream packet batch leases. | A dedicated serial queue **per input operation/session** for blocking C calls, not a cooperative Swift actor thread. | Mechanism: open/probe/read/seek/flush/close and typed mapping. No selected-track, retry, EOF-final, or playlist policy. |
| `VideoDecodeExecutor` | Adapted `VideoDecoder`, executor-local `AVCodecContext`, reusable `AVFrame`, owned codec-parameter/config lease, VT/software buffers and conversion state. | Dedicated serial decode queue per active decoder revision. | FFmpeg send/receive and format conversion. Reports typed VT/software failure; never invokes seek/fallback itself. |
| `AudioDecodeExecutor` | Adapted `AudioDecoder`, executor-local audio codec/reusable frame and lazy `SwrContext`, PCM batch storage. | Dedicated serial decode/conversion queue. | Decode, sample-accurate trim mechanism, decoder and resampler drain. No clock/recovery policy. |
| `PresentationExecutor` | Adapted `NativePresentationCoordinator`, revisioned required presenters, `AVSampleBufferRenderSynchronizer`, graph/sink leases. | **One nonblocking, bounded, control-priority commit sequencer** for membership, audio, video, rate, flush request, reset, and fence revision. Main actor only through the ordered endpoint described below. | Validate authority/revisions at each item commit and report sink capacity, partial submission, requested/observed rate, clock/status/flush, and failure. No preroll/EOF/buffering/recovery policy. |
| `SubtitleExecutor` | Split `SubtitlePipeline`, `LibassContext`, attachments, render batch vault. | One serial libass worker; final overlay mutation on main actor with revision recheck. | Parse/process/render/reset mechanism. No selected-track or clear policy. |
| `PersistenceExecutor` | `PlaybackPersistenceStore`, `AtomicPlaybackSessionStore`, serialization/file handles. | Actor or serial utility queue. | Read/write only; no resume/playlist policy. |
| `PlatformExecutor` | `NativePlayerSurfaceHost`, `NativePlayerNSView`, PiP, Now Playing, window/display/power objects. | `@MainActor`. | Apply explicit shell/platform effects and report facts; no playback lifecycle policy. |
| `DiagnosticsExecutor` | Logger/signposts/replay file writer. | Dedicated noncritical queue. | Formatting/export only. It cannot feed policy through localized strings. |
| `ResourceDirectory` / `ShutdownExecutor` | Lease metadata/provenance/custody/borrows, cancellation tokens, worker registrations, release/join bookkeeping—**not reusable C objects**. | Locked metadata directory plus release on each immutable storage executor. | Register core-issued release requests, wait for custody/borrows/in-flight calls, route physical release to storage, and return one delivered completion/failure result. Core remains authority for logical quiescence. |

Long-lived `AVFormatContext`/`AVCodecContext`, reusable `AVFrame`, `SwrContext`, and libass state never leave their storage executor. The input executor creates an owned decoder configuration using `avcodec_parameters_alloc`/`avcodec_parameters_copy` (or a complete immutable serialized equivalent) before another queue can configure a decoder; it never passes `FFmpegDemuxer.codecParameters`’ borrowed `AVFormatContext` pointer across queues. Explicitly retained/movable packet, pixel-buffer, PCM, sample-buffer, and subtitle-render batches use typed lease storage with consume/borrow rules and release on the immutable storage executor. The central directory tracks logical provenance, current custodian, child borrows, and in-flight-use count. A release requested during a borrow/C call becomes pending and cannot physically free storage until those uses settle.

Mixed demux output is never one single-owner batch consumed by three executors. The input executor returns per-stream child leases (or an explicitly reference-counted split); video, audio, and subtitle children settle independently, and the parent is released only after all children are consumed, cancelled, or released.

### 9.2 Main actor

The main actor owns only SwiftUI/AppKit-facing objects and Apple APIs that require it:

- `PlaybackViewStore` snapshot publication;
- `AppModel` window/chrome/panel state;
- `NativePlayerNSView`, layers/surface attachment, display/EDR updates;
- `SubtitleOverlayView` final update after revision validation;
- `NativePictureInPictureController`;
- Now Playing/remote command integration;
- workspace sleep/wake and termination callbacks.

It must not perform `avformat_open_input`, `avformat_find_stream_info`, `av_read_frame`, codec creation, `Data(contentsOf:)` for subtitles, libass processing, or busy wait for readiness/shutdown.

A serial worker queue is not a fence if it fire-and-forgets an asynchronous main-actor mutation. Any presentation or overlay operation that must cross to the main actor travels through one ordered `@MainActor` sink endpoint with monotonically increasing commit tickets. The endpoint installs/checks the current authority and revision immediately before the actual framework/view call, executes fence/clear/commit in ticket order, and acknowledges only after that call. The worker holds no lock while hopping to the main actor. Barrier tests pause both immediately before the hop and immediately before the final call. A late old subtitle clear is rejected just like a late old overlay frame, so it cannot erase a newer subtitle.

### 9.3 Core event serialization

Callbacks from all executors call `PlaybackEventLoop.send(envelope)`. The loop assigns the accepted journal sequence. It reduces without suspension, publishes a monotonically increasing snapshot revision, and schedules effects. A delayed main-actor publication must refuse to replace a newer snapshot revision.

For real runtime ordering, an event’s `observedAt` is diagnostic/input data; it does not by itself reorder the mailbox. Tests can explicitly reorder envelopes. The replay records the actual accepted total order, not an imagined deterministic OS schedule.

### 9.4 Demux, decoder, presentation, and subtitle work

- Each input’s opening/probing/reads/seeks/closes share that input executor’s serial FFmpeg ownership. An atomic interrupt callback is installed on the allocated `AVFormatContext` before `avformat_open_input`; at each `avformat_open_input`, `avformat_find_stream_info`, `av_read_frame`, and `avformat_seek_file` boundary it publishes the exact active effect token, and clears/advances it on return. Cancellation compares its target token, so a late cancel for call A cannot interrupt call B on the same context. `avformat_close_input` never runs concurrently with the blocked call. Interruption is best-effort and protocol/call dependent, so results distinguish requested, interrupted, physically closed, and timed-out/nonquiescent. A blocked old per-input queue cannot head-of-line block replacement opening on a new queue, but quarantined timed-out input/decoder workers and retained bytes have strict application/session caps; exceeding them rejects another load or escalates shutdown rather than creating unbounded stuck threads.
- Data queues use core-issued credits and runtime byte/item/duration budgets. Control cancellation/fence messages have a separate priority path; a full packet queue cannot prevent seek/stop/shutdown.
- Video and audio decode execute concurrently, but results reenter the same core mailbox.
- A midstream video resolution/pixel-format/color change or audio sample-rate/channel-layout change is a new decoder/format revision, not an in-place silent mutation. The core stops old grants, fences old-format batches, drains or releases them by policy, commands video format-description or audio `SwrContext` recreation, and re-enters required-stream preroll. This fixes the current audio assumption that the first-frame converter configuration remains valid for the whole stream. Format change during seek, EOF drain, recovery, or track replacement is resolved by the authoritative transaction and can never revive an old-format batch.
- Presentation owns one serial, bounded commit fence across current renderer membership and synchronizer. It never busy-waits for `isReadyForMoreMediaData` while holding the control gate: sink-capacity callbacks/events or bounded nonblocking enqueue quanta return control so seek/replace/stop/shutdown fences remain prompt. Separate decode concurrency cannot create separate high-level clocks.
- Fence installation plus the ordered **request** to flush/reset is atomic with respect to sample commits; actual video/audio flush/reset acknowledgments are separate events. The gate never blocks waiting for an asynchronous flush callback. Late, duplicate, dropped, and unavailable flush completion evidence is modeled explicitly.
- Subtitle libass work is serial per subtitle revision. Libass event reset and visible overlay clear are separate ordered results, and the final main-actor clear/overlay endpoint rechecks authority, subtitle revision, and surface revision.
- Shutdown tracks **all** active and superseded session workers. Replaced-session joins cannot live in detached, untracked tasks.

The runtime also installs an application-epoch tombstone before acknowledging final quiescence. Callback bridges consult it before constructing or enqueueing an event. During `.shuttingDown`, lease-bearing late results still enter the core so their explicit disposition can advance cleanup. After the core publishes `.terminated`, a hostile delayed callback cannot ask the core to emit cleanup: the bridge rejects it, returns custody/borrows, schedules physical disposal on the immutable storage executor, and records an out-of-band diagnostic. Non-resource callbacks are dropped. Tests inject callbacks on both sides of this boundary; a post-terminal event that nevertheless reaches `PlaybackCore.update` must return `.ignoredAfterTermination` and an empty effect list.

### 9.5 Drain observation

Apple sample-buffer renderers do not expose a single universally sufficient “queue empty and audible/displayed” callback. Before migrating EOF authority, implement and qualify a conservative, explicit presentation-drain contract using:

- explicit per-stream `SubmissionHorizon` (`none`, known end/count, or unknown timestamp/count);
- synchronizer media clock crossing that end while rate/status are valid;
- renderer status/failure and sink-backpressure/automatic-flush callbacks, while explicitly treating `isReadyForMoreMediaData` as neither preroll nor queue-empty evidence;
- an explicit audio/video safety tolerance and virtual-time timeout policy;
- flush/revision facts so an old drain cannot finish a new generation.

The presentation executor reports raw facts or a hard platform completion callback. `SynchronizationReducer`—not the executor—applies the documented tolerance and timeout policy and decides whether the evidence proves a required stream drained. Synchronizer clock crossing is scheduling evidence, not by itself proof of audible/displayed output. If the available facts cannot prove drain for a format, state remains `unconfirmed`; timeout must not be relabeled as clean EOF.

Integration cases must include pause during final drain; seek/stop/replacement during drain; audio-only, video-only, and no-frame inputs; renderer failure/flush during drain; audio route change/automatic flush; nonzero/negative origins and container/stream duration disagreement; and last-frame/last-tone sentinels.

### 9.6 Presentation graph, surface, and PiP lifetime

Match the useful part of current ownership explicitly: create an application-authority `PresentationGraphLease` owning one graph revision’s synchronizer, video display layer and its fixed `sampleBufferRenderer`, commit gate, and renderer-membership registry. Each playback-authority session obtains a revisioned graph borrow and configures exactly its required audio/video sink membership behind the fence. Replacing A/V with video-only, audio-only, or no-output media removes obsolete sinks from preroll, clock, rate, drain, and failure policy before their late callbacks can commit; an absent audio renderer cannot remain an implicit clock master. `NativePlayerSurfaceHost` and `NativePictureInPictureController` receive separate borrow leases to that display layer. Surface detach releases only its borrow and cannot destroy a layer still borrowed by PiP.

If video recovery truly requires a new renderer, allocate a **new presentation graph and display-layer revision**. After new session sinks are prepared, a main-actor platform transaction rebinds the surface and a new/reconfigured PiP content source/controller to the new layer, acknowledges both object revisions, then revokes/releases the old borrows and graph. If that rebind cannot be made safely while PiP is active, the approved policy must stop/restart PiP or fail recovery; it cannot pretend a stable layer’s renderer changed. The old graph releases only after session/surface/PiP borrows and callbacks quiesce.

Test A/V→video-only→audio-only→no-output membership permutations and callbacks after every membership revision. Test PiP active across file replacement and full graph/display-layer replacement: surface and PiP must rebind to the new layer, prior-file pixels must disappear, and old-layer/controller callbacks must be rejected. Also cover detach/reattach, display change, stop, and shutdown. Preserve the current lock-backed, nonisolated PiP time-range/paused projection so AppKit’s synchronous callbacks do not query the core actor; the event loop updates that projection from accepted snapshots. Current native PiP does not composite `SubtitleOverlayView` into the PiP image; preserve and document that omission unless subtitle-in-PiP is separately approved as parity work.

## 10. UI and reactive-shell integration

### 10.1 Shell contract

Introduce a main-actor observable view store:

```swift
@MainActor
@Observable
public final class PlaybackViewStore {
    public private(set) var snapshot: PlaybackUISnapshot
    public private(set) var revision: UInt64
    private let enqueueCommand: @Sendable (PlaybackCommand) -> Void

    public init(
        snapshot: PlaybackUISnapshot,
        revision: UInt64 = 0,
        enqueueCommand: @escaping @Sendable (PlaybackCommand) -> Void
    ) {
        self.snapshot = snapshot
        self.revision = revision
        self.enqueueCommand = enqueueCommand
    }

    public func send(_ command: PlaybackCommand) {
        enqueueCommand(command)
    }
}
```

The closure targets a thread-safe, nonisolated event-loop enqueue backed by its mailbox/`AsyncStream`; alternatively it creates the explicit `Task { await eventLoop.send(...) }` hop. A main-actor synchronous method must not call an actor-isolated method as though it were synchronous. The exact event-loop reference can be hidden behind a `PlaybackCommandSink`. Views receive `snapshot` and command closures. No view receives mutable `PlaybackMachineState`, executor handles, backend objects, or public lifecycle mutators.

- `PlayerRootView` reads the snapshot; dismissing an error sends `.dismissFailure` instead of `model.state.setError(nil)`.
- `PlaybackControlBar` may keep ephemeral drag visuals, but preview/exact ordering and latest-wins behavior live in `SeekReducer`; debounce uses explicit scheduler events.
- `PlaylistSidebar` renders each `PlaybackPlaylistItemSnapshot`, including progress, and sends selection commands. It no longer queries `PlaybackCoordinator.playbackProgress(for:)` row by row and cannot advance on EOF itself.
- `VideoSurface` hosts an opaque native surface and reports attach/detach/display facts; it never owns playback lifecycle.
- Now Playing remote handlers send the same commands as the UI and publish metadata derived from snapshot revisions.
- `SettingsView` and `PlayerCommands` read `PlaybackCapabilitiesSnapshot`; clear-history and reset-all-video-adjustments send explicit commands instead of invoking coordinator side methods.

### 10.2 Current object disposition

- **`PlaybackState`: Replace.** During migration, adapt it as a one-way projection from `PlaybackUISnapshot`; remove its authoritative lifecycle mutators. When views are migrated, replace it with `PlaybackViewStore`/snapshot. Shell-only properties move to `AppModel` or a small `AppShellState`.
- **`PlaybackCoordinator` / `PlaybackController`: Split.** Preserve its public facade temporarily. Move deterministic policy to `PlaybackCore`, serialized dispatch/journal to `PlaybackEventLoop`, executor wiring to `NativePlaybackRuntime`, and UI publication to `PlaybackViewStore`. Folder panel/discovery entrypoints may remain in a product coordinator.
- **`AppModel`: Adapt/Split.** Keep window, chrome, panels, sidebar preference, and AppKit observers. Replace direct player state mutation and lifecycle policy with command dispatch and snapshot observation.
- **`NativeAppleBackend`: Split/Replace.** First wrap it as a coarse native executor for shadow/vertical migration. Then move its policy/timer/seek/track/EOF/shutdown decisions into reducers and split framework mechanisms into executors. Remove the orchestration class after native gates pass.
- **Native playback session (`MediaSession`): Split/Replace.** Preserve its proven demux/decode/presentation loop mechanics behind coarse adapters, then divide them among the input, video, audio, presentation, subtitle, resource, and shutdown executors. Remove its lock-owned generation, seek, preroll, EOF, recovery, and shutdown policy as each reducer slice becomes authoritative.
- **Video surface:** Adapt. Keep `NativePlayerNSView`, `NativePlayerSurfaceHost`, `VideoSurface`, viewport/layout, drag/drop, and display-capability mechanics; make lifetime and callbacks revision-scoped.
- **Subtitle overlay: Keep unchanged.** `SubtitleOverlayView` remains a dumb AppKit renderer; the separate identity-validated main-actor commit bridge controls all clear/overlay mutations.
- **Persistence coordinator/store:** Adapt. Keep schemas and atomic storage initially. Replace direct writes from `PlaybackCoordinator` with effects/results; keep calendar/filesystem concerns outside the core.
- **`NowPlayingCoordinator`: Adapt.** Read snapshots and send commands. It must not infer lifecycle from a mutable shared object or bypass the event loop.
- **`PlaybackSystemCoordinator`: Adapt.** Observe `NSWorkspace`/display changes and execute idle-sleep effects. Move resume-after-wake and playback eligibility policy to `LifecycleReducer`.

Existing controls, playlist behavior, progress restore, fullscreen/window behavior, PiP, Now Playing, file panels, drag/drop, sidebar/chrome behavior, and packaging remain compatibility gates throughout. The refactor changes their authority path, not their product design.

## 11. Fuzzing and deterministic replay architecture

### 11.1 Model runtime

Add a test-only `PlaybackModelRuntime` that interprets `PlaybackEffect` values without FFmpeg or Apple frameworks. It owns virtual resource leases, configurable queue capacities, a virtual scheduler, and a seeded PRNG. It schedules typed result events rather than calling production APIs.

Use the existing Swift Testing dependency and a small in-repository seeded generator first; no generic Redux/TCA or fuzz dependency is required. A future libFuzzer entrypoint may decode replay DTOs, but the primary system is deterministic state/model fuzzing.

The harness supports:

- randomized valid and invalid command/platform/result sequences;
- virtual monotonic time and explicit deadlines;
- completion reordering across executors;
- duplicate result events and callback sequences;
- arbitrary bounded delay;
- stale session, generation, operation, effect, stream, track revision, surface revision, and decoder revision;
- dropped completions, with fair bounded retry/timeout scenarios distinguished from permanent-loss safety tests;
- injected open/demux/decode/VideoToolbox/audio-converter/renderer/libass/persistence/release failures;
- packet/frame queue starvation and backpressure;
- partial decode/enqueue/subtitle-batch progress or failure at every item boundary, with retained remainders;
- sink-can-accept callbacks before any commit, delayed/stale effective-rate observations, and pause/fence preemption;
- malformed, unknown, negative-start, discontinuous, overflowing, and missing timestamp metadata;
- EOF during seek and seek after EOF;
- seek during recovery;
- track switch during load/preroll/seek/recovery;
- shutdown during open, read, seek, decode, presentation, subtitle render, persistence, and release;
- late old-session VT recovery, rate callback, subtitle commit, EOF, and release result;
- external subtitle load racing embedded packet input;
- embedded/external subtitle invalidation while parse/render/font work is blocked;
- midstream video/audio format changes during seek, drain, recovery, and replacement;
- operation-targeted AVIO cancel/success races and quarantine-cap exhaustion;
- old surface/display/PiP object callbacks plus detach/fullscreen/sleep/wake during every lifecycle phase.

The generator should create mostly causally plausible events from emitted effects, then deliberately mutate a percentage of them. This produces useful deep sequences while still testing hostile input. Effects carry `EffectID`, so a shrinker can remove or simplify a causal pair without leaving meaningless references unless that is the fault being tested.

### 11.2 Required invariants

Run invariants after every transition, not only at final state.

1. Old-session or old-generation video/audio frames are never committed to the current presentation fence.
2. Old-generation or duplicate EOF cannot finish the current session.
3. Queue item, byte, media-duration, and granted-credit counts never exceed configured limits or become negative.
4. Exactly zero or one seek transaction is authoritative; a superseded transaction cannot change position, readiness, or transport.
5. Actual transport cannot become `.playing` until every required current-generation preroll condition is satisfied and rate application is acknowledged.
6. EOF is not final until every required stream reaches decoder drain, converter drain where applicable, submitted horizon, and accepted presenter drain.
7. Decoder recovery cannot reuse or commit old-generation output; decoder workers never cause a policy transition directly.
8. Subtitle output is invalidated and visibly cleared on seek, subtitle track/source change, file replacement, stop, and shutdown before new-revision output commits.
9. Under a fair scheduler and eventual cleanup delivery, shutdown eventually becomes quiescent and reaches `.terminated`. With permanently dropped completion acknowledgments, safety still holds and the machine remains explicitly timed-out/nonquiescent rather than claiming termination.
10. Once `.shuttingDown` begins, only final-checkpoint and cleanup effects are emitted. `.terminated` is entered only after subscriptions, executors, and leases are quiescent and emits no effects at all.
11. A logical long-lived or batch lease receives at most one release request and at most one physical release; no release may free a lease owned by another authority/revision. Under fair eventual delivery, every release is acknowledged exactly once and the logical ledger is zero before `.terminated`. Permanent result loss is a timeout-safety case, not an all-leases-released liveness proof.
12. Playlist advancement occurs at most once per completed media item and only for final current-session EOF.
13. Pause/resume preserves one consistent clock anchor/rate state; logical position cannot advance while an acknowledged pause is active except for an explicit new sample tolerated by policy.
14. A/V synchronization error stays inside the modeled bound or enters an explicit recovery/buffering state; it cannot silently diverge.
15. Every asynchronous effect context belongs to a live operation or is a cleanup effect for a known stale lease.
16. Each declared `(effect ID, parameterized result token)` or `(subscription ID, callback sequence)` is accepted at most once; required stream/component cardinality and phase order must be satisfied before a one-shot/phased effect reaches its terminal state once. A subscription remains outstanding after its cancel request and closes exactly once only on a matching original-context subscription terminal; later callbacks are rejected. Duplicates are state-idempotent except for rejection counters and cleanup.
17. No conflicting exclusive effect keys are emitted by one transition.
18. Logical queue occupancy equals outstanding batch lease summaries.
19. Applied presentation rate changes only on a matching acknowledgment.
20. Track, decoder, presentation, subtitle, and surface revisions agree wherever a commit is legal.
21. Logical playback time is explicitly valid/unknown/invalid, never non-finite; it is monotonic except during an authoritative seek/replacement/discontinuity.
22. A stale event may change only stale diagnostics and resource-cleanup state, never active playback policy or UI snapshot semantics.
23. Snapshot revisions strictly increase and a delayed main-actor publication never regresses the visible snapshot.
24. Stop/shutdown cancels or adopts every outstanding operation; cancel-request acknowledgment alone never proves a callback subscription quiescent, and no unowned subscription remains.
25. A batch item belongs to exactly one consumed prefix, retained remainder, produced output, or released slice; partial failure/backpressure/stale fencing cannot decode, enqueue, count, or release an item twice.
26. Sink backpressure availability cannot satisfy preroll. Playing requires committed current-generation sample thresholds and a matching observed effective nonzero rate; a request acknowledgment alone is insufficient.
27. A truncated/read-failed item may drain already accepted samples but never consumes the clean completion token or advances the playlist.
28. Old format/membership/surface/display/PiP revisions cannot mutate current sinks or platform objects; absent streams are not preroll, clock, drain, or failure participants.
29. Physical release occurs only on immutable storage ownership and only after all current-custodian work, child borrows, and in-flight C calls settle.

### 11.3 Serializable replay format

Use a versioned, purpose-built JSON DTO rather than relying on the permanent encoded layout of internal Swift enums. Redact absolute user paths or express sources as fixture-relative IDs.

```json
{
  "schemaVersion": 1,
  "superplayrRevision": "fbdc699...",
  "modelVersion": 1,
  "seed": 847221,
  "initialState": { "...": "canonical value state" },
  "configuration": {
    "queueLimits": { "...": "..." },
    "faultPolicy": { "...": "..." }
  },
  "steps": [
    {
      "sequence": 17,
      "virtualTime": 530000,
      "inputEvent": { "...": "full scoped event" },
      "disposition": { "kind": "stale", "reason": "generationMismatch" },
      "preStateDigest": "sha256:...",
      "postStateDigest": "sha256:...",
      "generatedEffects": [{ "...": "typed descriptor" }],
      "leaseDelta": { "acquired": [], "released": [42] },
      "scheduledCompletions": [{ "...": "event/fault/delay" }],
      "invariantResults": []
    }
  ],
  "rejectedStaleEvents": [17],
  "finalState": { "...": "canonical value state" },
  "outstandingEffects": [],
  "outstandingLeases": [],
  "failedInvariant": {
    "name": "oldGenerationFrameNeverCommitted",
    "step": 17,
    "details": "..."
  },
  "shrinkHistory": [{ "fromSteps": 142, "toSteps": 11 }]
}
```

Record both full canonical states for test artifacts and compact digests for long runs. The normal production journal can use bounded/redacted transition summaries and opt-in full replay capture.

Canonical replay is an explicit projection, not synthesized `Codable` for internal containers. The encoder converts every `Set` (including completion alternatives and active borrows) to an array sorted by the complete stable token/ID tuple, converts every dictionary to entries sorted by canonical key, uses fixed enum tags and JSON key order, and normalizes integer/string representation. The effect planner likewise sorts candidate intents and exclusive keys explicitly; emitted effect order must never depend on `Set` or `Dictionary` iteration. A Stage-1 determinism test constructs equivalent states and ledgers with deliberately shuffled insertion histories and requires identical effect arrays, canonical replay bytes, and state digests.

Shrinking proceeds in deterministic passes:

1. delete contiguous step ranges while retaining the failure;
2. remove independent operations and their completions;
3. simplify reorder/delay/drop/fault choices;
4. shrink media times, queue sizes, retry counts, and track catalogs;
5. normalize IDs while preserving causal references;
6. confirm the minimized replay at least twice from the serialized initial state.

Every minimized failure becomes a checked-in deterministic replay fixture under the future `Tests/SuperplayrPlaybackCoreTests/ReplayFixtures/` plus a named regression test. The test must state the invariant and original seed, not just replay opaque bytes.

### 11.4 Fuzz tiers

- **Per-commit:** thousands of short pure-core sequences, fixed regression replays, no native libraries.
- **Nightly/extended:** longer seeded model runs, mutation/shrink, replay artifact upload, all fairness/drop profiles.
- **Native deterministic barriers:** a controllable fake presentation/subtitle executor pauses immediately before final commit so tests can invalidate the generation and prove rejection.
- **Generated-media integration:** execute core/runtime with real fixtures and injected executor failures.
- **Stress/sanitizer:** retain and extend the POC ASan/TSan/reopen/leak/long-run harness, but drive it through structured operations and record the semantic journal.
- **Physical macOS release:** sleep/wake, display move/disconnect/EDR, fullscreen, audio route/device, HDR/rotation, PiP, notarized app, and actual tail/seek perception.

## 12. mpv behavior and test translation strategy

`Documentation/MpvReferenceAnalysis/` pins exact reference revisions and already separates loading/demux, seeking/EOF, video, audio/sync, subtitles, recovery, picture quality, dependencies, gaps, and fixtures. Use mpv as a behavioral oracle and scenario source—not as a runtime, type hierarchy, or code template.

With FC/IS authority complete, this translation is now the next workstream. The
priority is: (1) immutable mpv/Superplayr/fixture manifests and one retained
end-to-end artifact; (2) self-verifying VFR, timeline, corrupt/truncated, tail,
and format-change fixtures; (3) load/selection/timeline then seek then EOF/drain
differentials; (4) deterministic fault/race policy comparisons through the
production seams; and (5) calibrated presentation and physical gates. Detailed
sequencing is in
[MpvReferenceAnalysis/TEST_FIXTURE_PLAN.md](MpvReferenceAnalysis/TEST_FIXTURE_PLAN.md).

For every candidate behavior, add a small provenance record:

```text
scenario → expected invariant → actual implementation owner
         → Superplayr event sequence → core test
         → real-media fixture test if mechanism-dependent
         → supported / intentionally omitted / pending platform proof
```

Apply the same six-step translation every time: (1) identify the pinned scenario and observable invariant; (2) classify its real owner as mpv policy, FFmpeg, libass, Apple API, or Superplayr; (3) express it as Superplayr commands/events without importing mpv state; (4) add the smallest deterministic core/model test; (5) add a generated-media or physical integration test only where the actual mechanism matters; and (6) record supported, intentionally omitted, or pending behavior with provenance. This record is reviewed when any source pin changes.

| Behavioral scenario | Actual owner | Superplayr event/invariant translation | Core test | Media/platform integration | Status policy |
|---|---|---|---|---|---|
| Cancel load/read promptly | Superplayr control + FFmpeg AVIO | Load/open effect, then replacement/stop/shutdown; old open/read may return only stale cleanup. | Drop/delay/cancel open and read results; assert bounded cleanup state. | Blocked custom AVIO fixture and close at each phase. | Required before quiescent shutdown claim. |
| Explicit syncing/ready/playing/draining states | Superplayr core; behavior learned from mpv | Required stream readiness and drain events gate actual transport and EOF. | No play before preroll; no EOF before drain. | A/V, audio-only, video-only, delayed-frame fixtures. | Required. Do not port mpv state structs. |
| Backward demux seek + decode-forward exact landing | FFmpeg mechanism + Superplayr policy | `.seek(exact)` → invalidate/flush → demux landing → reject/trim pre-target video/audio → preroll. | Reorder/duplicate seek phases; exact floors and one transaction. | CFR/VFR, non-zero/negative start, long GOP, near EOF. | Required. |
| Exact audio starts at target | Superplayr audio policy/mechanism; FFmpeg decoded frames | Audio descriptor crossing target gets sample trim before enqueue; no early audible samples. | Sample-range arithmetic and stale trim result. | Click/impulse fixture around target; compare first audible timestamp. | Required; current whole-frame acceptance is insufficient. |
| Queued seek near EOF must not suppress/forge EOF | Superplayr core; scenario observed in mpv issue/fix history | EOF during authoritative seek is provisional; final exact seek wins, then current-generation drain decides EOF. | EOF-before/after seek completion with duplicates/stale generations. | Near-EOF long-GOP fixture. | Required. |
| Delayed decoder frames and presentation tail | FFmpeg decoder + Apple presentation + core EOF policy | Separate demux EOF, decoder/converter drain, submitted horizon, presenter drain. | All permutations of drain results. | B-frame/video and resampler-tail audio fixtures; measure last output. | Required. |
| Latest preview, final exact priority | Superplayr seek policy | Preview commands/ticks coalesce; exact command supersedes all previews. | Random rapid preview/exact sequences and dropped completion. | Existing rapid-seek fixture expanded with barrier hooks. | Required. |
| Timeline origin/discontinuity handling | FFmpeg metadata + Superplayr logical timeline | Catalog result explicitly maps container timestamps to logical zero; invalid/discontinuous values are events/faults. | Negative/unknown/overflow/discontinuity model cases. | Non-zero-start, negative-start, MPEG-TS discontinuity, malformed fixtures. | Required before broad formats. |
| Hardware failure fallback | FFmpeg/VideoToolbox mechanism + Superplayr recovery policy | Typed video failure returns to reducer; core invalidates generation and explicitly recreates software path/reprerolls. | Failure during load/seek/replacement/shutdown; retry budget. | Fault adapter around VT plus real software decode. | Required; do not copy mpv decoder internals. |
| Bounded queues with control priority | Superplayr runtime/core | Credits bound count/bytes/time; seek/stop/shutdown bypass blocked data grants. | Full queues plus every control command. | High-bitrate/large-frame fixture and blocked producer. | Required. |
| A/V clock and pause/resume | Apple synchronizer mechanism + Superplayr policy | Explicit clock/rate acknowledgment, bounded modeled error, one pause anchor. | Virtual drift/jitter/starvation and pause/resume sequences. | Current long fixtures plus audible/displayed probes. | Initial policy should preserve current Apple synchronizer, then tune. |
| Subtitle reset/track replacement/fonts | libass mechanism + Superplayr ownership/revision policy | Invalidate libass/overlay revision on seek/track/file; reject old render at final commit. | Old packet/render/clear after every invalidation. | ASS/SRT/fonts/heavy animation, embedded↔external races. | Required. |
| Error and teardown semantics | Superplayr plus FFmpeg/Apple cancellation limits | Typed fault enters recovery/failure; all queues/leases close; `.shuttingDown` emits cleanup only and `.terminated` emits nothing. | Failure/drop/reorder at every phase. | Corrupt/truncated files, renderer fault shim, reopen/leak/sanitizer. | Required. |
| Picture quality/color/display | FFmpeg metadata + VideoToolbox + Apple presentation/platform | Format/display revisions and accepted metadata values; no playback-policy dependency on UI object lifetime. | Revision/stale display facts. | HDR/HLG/P010/SAR/color/interlace/rotation and physical display matrix. | Preserve current native path; Metal/libplacebo is intentionally out of scope. |

Do not port `MPContext`, mpv commands/properties, mpv queue structures, C state layouts, implementation control flow, or substantial source/comments. For behavior actually owned by FFmpeg or libass, test the Superplayr adapter with the pinned library behavior rather than mislabeling it as an mpv feature. For behavior tied to Apple renderers, record that owner and keep a physical/API-specific test. Unsupported or intentionally omitted behavior belongs in a checked-in behavior matrix with rationale and product decision.

## 13. Current-file keep/adapt/split/replace matrix

“Keep unchanged” means no architectural ownership change is expected, though imports/call signatures may receive mechanical updates. “Remove after migration” means retain until the relevant rollback and qualification gates close.

| Current path/type | Classification | Target disposition |
|---|---|---|
| `Package.swift` | **Adapt** | Add `SuperplayrPlaybackCore` and its tests early. Late in migration, remove `CMpv`, legacy dependencies, OpenGL, and dual-backend product wiring. Do not update third-party versions as part of this refactor. |
| `Sources/SuperplayrCore/Player/MediaSource.swift` | **Keep unchanged** | Reuse source/value identity; add a separate redacted/fixture-relative replay representation rather than encoding private absolute paths into artifacts. |
| `Sources/SuperplayrCore/Player/MediaTrack.swift` | **Adapt** | Preserve UI metadata; introduce stable `PlaybackTrackID`/catalog revision mapping so a raw FFmpeg index is not the only identity. |
| `Sources/SuperplayrCore/Player/PlaybackModels.swift` | **Adapt** | Reuse product-facing buffer/video/display/chapter values in snapshots; keep runtime-only revisions/timestamps in the new core module. |
| `Sources/SuperplayrCore/Player/PlaybackPhase.swift` | **Adapt** | Retain as a derived UI phase, not authoritative machine state. |
| `Sources/SuperplayrCore/Player/PlaybackCommand.swift` | **Adapt** | Expand it in the lower-level `SuperplayrCore` values module so `SuperplayrPlaybackCore` can consume it without a dependency cycle; add play/pause/playlist/track/lifecycle and explicit capability commands now expressed as direct backend methods. A later values-only module is optional, not required for this refactor. |
| `Sources/SuperplayrCore/Player/PlaybackState.swift` (`PlaybackState`) | **Replace** | Transitional one-way snapshot adapter, then `PlaybackViewStore` + immutable `PlaybackUISnapshot`. Remove public lifecycle mutators and split shell-only UI state. |
| `Sources/SuperplayrCore/Playlist/FolderPlaylist*.swift`, `ExternalSubtitleMatcher.swift` | **Keep unchanged** | Keep discovery/matching/value mechanics. Feed accepted results into core events; core owns only current playlist/cursor/completion token. |
| `Sources/SuperplayrCore/Persistence/PlaybackPersistenceStore.swift` | **Adapt** | Keep storage schema and locking initially; invoke through `PersistenceExecutor`, return typed completion, and remove direct coordinator policy. |
| `Sources/SuperplayrCore/Persistence/PlaybackSessionStore.swift` | **Adapt** | Keep atomic file storage; separate pure record values from I/O and make restore/save effects explicit. |
| `Sources/SuperplayrCore/Persistence/PlaybackPreferences.swift` | **Adapt**, then **Remove after migration** for backend selection | Preserve user playback/shell preferences. Native becomes the only backend; delete `PlaybackBackendPreference` and migrate old stored values at the final native-only stage. |
| `Sources/SuperplayrPlayback/PlayerBackend.swift` (`PlayerBackend`, `PlayerBackendKind`) | **Remove after migration** | Temporary compatibility facade only. The target is a concrete native runtime, not a new generic backend protocol. |
| `Sources/SuperplayrPlayback/PlayerBackendEvent.swift` (`PlayerBackendEvent`, `PlayerEventGate`) | **Replace** | Superseded by scoped `PlaybackEvent`, `PlaybackTransition`, effect ledger, and executor commit fences. Keep bridge conversion while the current backend is wrapped. |
| `Sources/SuperplayrPlayback/BackendSelection.swift` | **Remove after migration** | No dual-backend selector in the native-only target. |
| `Sources/SuperplayrPlayback/PlayerCapabilities.swift` | **Adapt** | Keep product capability values if UI needs them, but make them native build/runtime capabilities rather than backend comparison data. |
| `Sources/SuperplayrPlayback/PlayerSurfaceHost.swift` | **Adapt** | Preserve opaque surface hosting during migration; eventually use a native surface handle/revision contract rather than a backend-neutral lifecycle owner. |
| `Sources/SuperplayrPlayer/Player/PlaybackController.swift` (`PlaybackCoordinator`) | **Split** | Product/file-panel/folder-discovery facade, `PlaybackEventLoop`, `NativePlaybackRuntime`, and `PlaybackViewStore`. Remove migrated direct policy and persistence/framework calls slice by slice. |
| `Sources/SuperplayrPlayer/Player/ArchitectureValidation.swift` | **Replace/Adapt** | Add import/API architecture checks for the pure core, no direct UI lifecycle mutation, no worker recovery policy, native package dependencies, and no POC/legacy residue. Preserve useful product checks. |
| `Sources/SuperplayrPlayer/Player/LegacyMpvBackend.swift`, `LegacyMpvSurfaceHost.swift`, `Mpv*.swift` | **Remove after migration** | Retain only until native acceptance/removal gate. Do not route them through the new core or add parity work. This is roughly 1,960 current lines plus related glue. |
| `Sources/SuperplayrNativePlaybackPOC/Production/NativeAppleBackend.swift` | **Split**, then **Remove after migration** | Extract mechanisms into runtime composition; move timer/load/seek/track/EOF/recovery/shutdown policy to reducers. Use as coarse adapter/reference until equivalent qualification passes. |
| `Sources/SuperplayrNativePlaybackPOC/Media/MediaSession.swift` | **Split/Replace** | Replace monolithic policy/worker orchestration with input, decode, presentation, subtitle, lease, and shutdown executors. Reuse narrow loops/mechanics only behind typed effects. |
| `Sources/SuperplayrNativePlaybackPOC/Media/FFmpegDemuxer.swift` | **Adapt** | Become the input executor’s serial resource. Add interruptible open/read, typed catalog/timeline results, cancellation, nonrecursive malformed-packet handling, and explicit close. |
| `Sources/SuperplayrNativePlaybackPOC/Media/FFmpegPacket.swift` | **Adapt** | Preserve move/deinit ownership, but store it in the runtime lease vault and expose only packet handles/descriptors. |
| `Sources/SuperplayrNativePlaybackPOC/Media/FFmpegStreamInfo.swift` | **Adapt** | Convert to stable, serializable catalog/timeline metadata and revision mapping. |
| `Sources/SuperplayrNativePlaybackPOC/Media/MediaTime.swift` | **Adapt** | Reuse rational conversion mechanics; add explicit valid/unknown/invalid logical time and origin mapping. |
| `Sources/SuperplayrNativePlaybackPOC/Media/VideoDecoder.swift` | **Adapt** | Keep FFmpeg/VT/software mechanics and buffer retention. Add typed errors/revisions/batches; remove any high-level recovery decision. |
| `Sources/SuperplayrNativePlaybackPOC/Media/AudioDecoder.swift` | **Adapt** | Keep decode/conversion mechanics; add sample-accurate exact trim, resampler tail drain, format revision handling, typed errors, and batch leases. |
| `Sources/SuperplayrNativePlaybackPOC/Playback/PacketQueue.swift` (`BoundedQueue`) | **Replace/Adapt** | Runtime queue primitive with item+byte+duration budgets, explicit credits, cancellation/control-priority path, and lease accounting. Preserve close-wakes-waiters behavior. |
| `Sources/SuperplayrNativePlaybackPOC/Playback/PlaybackGeneration.swift` | **Replace** | One core-owned checked `PlaybackGenerationID`, scoped end to end. |
| `Sources/SuperplayrNativePlaybackPOC/Playback/SeekCoordinator.swift` | **Replace** | `SeekReducer`/`SeekTransaction` with operation/effect IDs, explicit phase acknowledgments, failure/timeout, and replayable coalescing. |
| `Sources/SuperplayrNativePlaybackPOC/Presentation/NativePresentationCoordinator.swift` | **Split/Adapt** | One serialized `PresentationExecutor` and commit fence owning synchronizer plus both renderers. Remove preroll/transport/EOF policy. |
| `Sources/SuperplayrNativePlaybackPOC/Presentation/SampleBufferVideoPresenter.swift`, `Sources/SuperplayrNativePlaybackPOC/Presentation/SampleBufferAudioPresenter.swift` | **Adapt** | Keep sample-buffer construction/enqueue/flush mechanics. Surface both renderer statuses/errors, scoped completion, displayed/audible/drain evidence, and lease consumption. |
| `Sources/SuperplayrNativePlaybackPOC/Presentation/NativePlayerView.swift`, `Sources/SuperplayrNativePlaybackPOC/Production/NativePlayerSurfaceHost.swift` | **Adapt** | Keep AppKit view/layer/drag/display mechanics; add stable surface revision and event-only callbacks. |
| `Sources/SuperplayrNativePlaybackPOC/Presentation/VideoViewport.swift`, `Sources/SuperplayrNativePlaybackPOC/Subtitles/SubtitleGeometry.swift` | **Keep unchanged** | Pure geometry helpers remain reusable and tested. |
| `Sources/SuperplayrNativePlaybackPOC/Presentation/NativePictureInPictureController.swift` | **Adapt** | Main-actor platform executor with scoped start/stop/results; no lifecycle authority. |
| `Sources/SuperplayrNativePlaybackPOC/Subtitles/SubtitlePipeline.swift` | **Split/Replace** | Serial subtitle executor mechanisms plus core-owned subtitle policy. Remove mixed-thread selection/enable/delay ownership and make track reset explicit. |
| `Sources/SuperplayrNativePlaybackPOC/Subtitles/LibassContext.swift` | **Adapt** | Keep pointer ownership and rasterization; add explicit track/event reset, revision-scoped operations, typed errors, and release completion. |
| `Sources/SuperplayrNativePlaybackPOC/Subtitles/SubtitleOverlayView.swift` | **Keep unchanged** | Remain a dumb AppKit drawing surface; only the identity-checked platform commit path may mutate it. |
| `Sources/SuperplayrNativePlaybackPOC/Subtitles/FontAttachmentStore.swift` | **Remove after migration** or repurpose | It is currently unused. Either make it the executor’s real attachment lease store with tests or delete it; do not leave a second ownership story. |
| `Sources/SuperplayrNativePlaybackPOC/Diagnostics/PlaybackDiagnostics.swift` | **Replace** | It is not production authority. Replace string-only observable diagnostics with structured transition/effect/rejection/lease journal data. |
| `Sources/SuperplayrNativePlaybackPOC/Diagnostics/PlaybackQualification.swift` | **Adapt** | Retain useful numeric helpers but distinguish submitted horizons from displayed/audible measurements and feed explicit clock/presentation facts. |
| `Sources/SuperplayrNativePlaybackPOCApp/NativePlaybackPOCApp.swift` | **Adapt** | Keep as native qualification/stress host, drive the new event loop, accept seed/replay/fault options, and remove wall-clock-only correctness assertions. Rename only after migration. |
| `Sources/SuperplayrApp/App/AppModel.swift` | **Split/Adapt** | Keep app-shell state and AppKit operations; observe snapshot/send commands. Move no playback policy into the shell. |
| `Sources/SuperplayrApp/App/AppDelegate.swift` | **Adapt** | Convert open/termination callbacks to events and wait for explicit terminal snapshot/result. |
| `Sources/SuperplayrApp/App/NowPlayingCoordinator.swift` | **Adapt** | Snapshot consumer and command producer only. |
| `Sources/SuperplayrApp/App/PlaybackSystemCoordinator.swift` | **Adapt** | Platform event source/effect executor only; remove duplicated sleep/wake resume policy. |
| `Sources/SuperplayrApp/UI/PlayerRootView.swift`, `Sources/SuperplayrApp/UI/PlaybackControlBar.swift`, `Sources/SuperplayrApp/UI/PlaylistSidebar.swift` | **Adapt** | Read snapshots and send commands. Keep local visual-only interaction state; eliminate direct lifecycle mutation. |
| `Sources/SuperplayrApp/UI/VideoSurface.swift`, `Sources/SuperplayrApp/UI/WindowAccessor.swift`, visual styling views | **Keep unchanged/Adapt** | Preserve visual behavior; mechanically connect to native surface revision/event API. |
| `Tests/SuperplayrNativePlaybackPOCTests/*` | **Adapt/Expand** | Preserve all current foundation/fixture coverage, make required-fixture absence fail in CI, add executor fault/barrier tests, and route through the core/runtime. |
| Other existing test targets | **Adapt/Expand** | Preserve product compatibility tests and translate policy assertions into pure reducer tests plus adapter/shell tests. |
| `Scripts/generate-native-poc-fixtures.sh` | **Adapt** | Preserve generated coverage; add negative/unknown/corrupt/discontinuous/format-change/audio-trim/EOF fixtures and a manifest with licensing/pins. |
| `Scripts/run-native-poc-qualification.sh` | **Adapt** | Make fixture presence, replay regressions, fault tests, native runtime, sanitizers, leak/resource-zero, package, and architecture gates explicit. |
| `Scripts/build-native-poc-app.sh`, `verify-app.sh`, `sign-and-notarize.sh` | **Adapt**, with verification mostly **Keep unchanged** | Reuse native closure prototype and packaging verification. Rename POC output late; preserve signing/notarization checks. |
| `Scripts/build-app.sh`, `bootstrap-libmpv.sh`, `copy-libmpv-dependencies.sh` | **Adapt**, then **Remove after migration** for mpv portions | Switch production packaging to the qualified native dependency closure; delete mpv bootstrap/copy logic only at the final gate. |
| Current architecture/POC/integration reports | **Adapt** | Mark historical scope clearly and publish a new authoritative native architecture/replay/qualification document after implementation. Do not rewrite history or treat untracked analysis as shipped documentation implicitly. |

## 14. Incremental migration stages

### Implementation reconciliation (2026-07-20)

The production implementation combined proposed stages and intentionally used
aggregate acknowledgements for tightly coupled native transactions. Therefore
the stage list below remains a requirements decomposition, not a literal
class/effect checklist.

Completed authority outcomes are: the pure deterministic core; the serialized
production driver and immutable reactive projection; scoped identity,
fences/leases, cancellation, seek, drain/EOF, recovery, synchronization,
track/subtitle and lifecycle authority; removal of obsolete native orchestration
and libmpv/OpenGL; and the native-only package. The completion gate passed with
the evidence recorded in
[NATIVE_PLAYBACK_QUALIFICATION.md](NATIVE_PLAYBACK_QUALIFICATION.md).

Still open as next-phase evidence are the pinned mpv/FFprobe runner and
comparator, fixture manifest/self-check breadth, retained differential
artifacts, and the full supported hardware/display/audio physical matrix. Those
gaps do not imply that any migrated production decision still has two owners.

The governing rule is: **exactly one implementation owns each migrated decision**. Shadow code may observe and compare but must never emit native effects. Each behavior-affecting stage has a developer-only native-orchestrator switch back to the immediately previous qualified native slice; the switch is removed when the next gate closes. This is not a new shipping backend abstraction.

### Stage 0 — Freeze and make the baseline honest

- Resolve the local Xcode/toolchain gate, run the current full native qualification with generated fixtures, and archive versions/results.
- Change the future CI invocation—not production behavior—so required fixture absence is a failure and optional long tests report “not run” explicitly.
- Record current native product behavior for launch/load/play/pause/seek/EOF/track/sleep/replace/stop/shutdown as semantic traces.
- Adopt or deliberately relocate the then-untracked mpv analysis and historical architecture report; do not accidentally mix them into implementation commits.
- Freeze broad native parity features. Only correctness fixes required to establish a trustworthy baseline proceed during the core migration.

### Stage 1 — Add the pure core, invariant checker, and replay DTOs beside production

- Add the `SuperplayrPlaybackCore` target and `SuperplayrPlaybackCoreTests` with identity/time/failure/state/event/effect/transition values, reducer composition skeleton, structured invariant checker, model runtime, deterministic generator, replay encoder/decoder, and shrinker foundation.
- Define hand-written canonical replay projections for every unordered collection and require explicit stable sorting before effect planning or encoding; never treat synthesized `Codable` output from `Set`/`Dictionary` as the replay wire format.
- Add architecture validation banning framework/concurrency/wall-clock imports and APIs in the pure target.
- No production command or native callback uses the new core yet.

### Stage 2 — Capture current behavior in shadow mode

- Add `PlaybackEventLoop` and a semantic adapter around `PlaybackCoordinator`, `PlayerBackendEvent`, and native snapshot/callback facts.
- Feed events to a shadow core and journal predicted transitions/snapshots, but discard all shadow effects.
- Establish mapping reports for every current flow and identify intentional semantic differences (`loaded` versus preroll-ready, submitted versus presented, optimistic stop, etc.).
- This stage validates observability and replay without changing playback.

### Stage 3 — Introduce the driver and coarse native runtime adapter

- Make `PlaybackEventLoop` the only serialized command/result path for a small non-risky slice: diagnostics, snapshot revisions, command rejection after shutdown, and persistence request/result identity.
- Wrap `NativeAppleBackend` as a coarse executor for unmigrated work; convert its events back into scoped results.
- Allocate deterministic session, operation, and effect IDs in the core. Keep current native generation internally until the next stages, but translate it explicitly.
- Preserve the `PlaybackCoordinator` facade and current views through the one-way snapshot adapter.

### Stage 4 — Make identity fences and resource leases authoritative

- Add global playback authority/effect context plus resource provenance/disposition to the runtime metadata directory.
- Serialize audio/video/rate/fence/flush-request ordering through `PresentationExecutor.installFenceAndRequestFlush` and final commit checks; keep asynchronous flush/reset acknowledgments explicit.
- Activate a **minimal `SubtitleReducer` slice now** for subtitle/overlay revision allocation, control-priority visible clear, source invalidation acknowledgment, and final commit rejection. Selection, loading, rendering policy, fonts, and track transactions stay in the coarse adapter until Stage 10, but seek/replacement cannot have a second clear authority.
- Track current and superseded session workers/resources in the logical lease ledger; stale results emit cleanup only.
- Prove control-path independence from data readiness: with either renderer held not-ready indefinitely, seek/replacement/stop/shutdown fences must still install and cancellation/release must progress within a virtual deadline. Exercise late readiness plus late/duplicate/dropped flush callbacks before and after any main-actor hop.
- Establish the application-epoch presentation graph, surface/PiP borrow leases, and post-terminal callback tombstone before any replacement policy relies on them.
- Do this before moving seek or replacement policy, because reducer-side identity without a final executor fence would preserve the current race.

### Stage 5 — Extract cancellable opening, probing, demux, and bounded work grants

- Move `FFmpegDemuxer` creation/open/probe/read off the main actor to `FFmpegInputExecutor`.
- Install best-effort AVIO interrupt callbacks before open; target the exact active open/probe/read/seek effect token at every C-call boundary, use per-input queues, and separately settle the cancel effect (`interruptRequested`/`targetNotActive`/failure) and original target effect (normal/failed/cancelled). Never close the format context concurrently with a C call, and cap quarantined timed-out input/decoder workers plus retained bytes.
- Copy codec parameters into owned decoder-configuration leases on the input queue; never hand another executor a pointer borrowed from `AVFormatContext`.
- Return stable catalog/timeline metadata; represent unknown/invalid duration/start/timestamps explicitly.
- Replace count-only orchestration with bounded item/byte/duration grants and per-stream child batch leases while retaining tested close-wakes-waiters semantics.
- The current native adapter remains responsible for higher-level seek/start/EOF policy until their stages.

### Stage 6 — Migrate relative, exact, preview, and rapid seeking

- Replace `PlaybackGeneration`, `SeekCoordinator`, backend preview flags/timer correctness, and `MediaSession.seek` policy with `SeekReducer` and root generation invalidation.
- Sequence commit-fence invalidation, read cancellation, decoder/presentation/subtitle flush acknowledgments, FFmpeg seek, decode-forward floor/trim, preroll, and rate restore through events.
- Move the **minimal generation-specific** preroll/rate-restore slice into `SynchronizationReducer` now. Disable `MediaSession.startIfPrerolled`, its seek completion/rate change, and worker-triggered recovery seek for core-owned generations, so no transaction has two generation/preroll/rate owners.
- Until Stage 8 replaces recovery policy, adapt a current-path hardware failure into a serialized compatibility recovery event that reuses the same core-owned generation/fence/seek/preroll transaction and the existing single fallback intent. The worker may report the fault and perform a commanded recreation, but it may not initiate a global seek itself; Stage 8 makes the classification and budget fully typed.
- Resolve relative seeks from explicit accepted clock samples.
- Implement sample-accurate audio trim, unknown-duration behavior, timeline origin mapping, seek failure/timeout, EOF-during-seek, recovery interaction, and final-exact priority.
- Make displayed-image policy explicit: an owner-approved same-media seek may retain the already-presented current-file image while reprerolling, matching today’s `removeDisplayedImage:false`; replacement, stop, and shutdown must remove it immediately. Preview has its own revision and can never leave prior-file pixels on the main layer or PiP.
- Run a preview-mechanism spike required by `Documentation/MpvReferenceAnalysis/SEEKING_AND_EOF.md`: compare a paused timestamped transaction on the synchronized video renderer against an isolated native video-only preview surface. Do not use `kCMSampleAttachmentKey_DisplayImmediately` under the synchronizer without physical/API qualification. Preview enqueues no audio or subtitles, and final exact seek revokes all preview output.
- Retain `MediaSession` only as a mechanism adapter for unmigrated load/EOF/recovery portions.

### Stage 7 — Migrate loading, EOF/drain, file replacement, and playlist advancement

- Make `SessionReducer`/`LoadingReducer` authoritative for load/replacement. Activate a **minimal `TrackSelectionReducer` slice** to deterministically choose and record requested/effective initial audio/subtitle defaults from the accepted catalog; loading consumes its internal selection fact rather than choosing tracks itself.
- Separate loaded/probed/configured/prerolled/playing states.
- Give `LoadingReducer` plus the minimal `SynchronizationReducer` from Stage 6 full authority over initial-load required-stream preroll and the first actual play-entry acknowledgment. The old backend/session may no longer mark a core-owned load playing. Stage 9 later adds buffering, drift, pause/lifecycle, and tuning policy; it does not become the first startup owner.
- Model the current post-load restore sequence explicitly: accepted load → persistence result → exact resume seek when saved position is over one second → first matched external sidecar loaded/selected. Record that later `select:false` sidecars are currently rejected rather than exposed; do not silently add multi-sidecar parity. Scope the sequence so replacement/seek/track changes reject stale restore work.
- Extend the minimal `SynchronizationReducer` slice only far enough to own required-stream drain facts/finalization; introduce explicit video/audio decoder, converter, submission, and presenter drain states and define/qualify the Apple drain contract before enabling core EOF. Stage 9 adds buffering/drift/lifecycle tuning rather than becoming the first EOF owner.
- Make final EOF and completion-token consumption atomic; emit persistence and next-load effects once.
- File replacement revokes global session authority first, keeps old leases until release, and never shares an unversioned sink.
- Reconfigure application-graph renderer membership for A/V, video-only, audio-only, and zero-output media behind the fence; remove old-file displayed pixels/PiP content before the new load can wait on readiness.
- Preserve current file/playlist construction and folder-restore selection as Stage-2 compatibility traces unless the owner approves a separate change.
- Preserve current transport compatibility explicitly: selecting the already active item resumes without reload; selecting it after EOF reloads; and Stop → Play reloads the selected item from the beginning because the stopped zero-position checkpoint wins. Treat a change to that checkpoint/restart behavior as a separate owner decision.

### Stage 8 — Migrate typed recovery and VideoToolbox fallback

- Remove policy from `MediaSession.recoverVideoDecoderFromHardwareFailure`.
- Return structured demux/video/audio/presentation/subtitle failures with stage/native code/codec/profile/format revision/consecutive count and configured-versus-actually-observed hardware output.
- `RecoveryReducer` owns retry budget, generation invalidation, software decoder recreation, repreroll, degraded-mode decision, or terminal failure. Initial compatibility policy is at most one VT→software fallback per **media-session + selected-video-stream lineage**; recovery-created decoder revisions and ordinary seeks do not replenish it. A new media session or committed new video-stream lineage may reset it. Only a classified hardware-path failure qualifies.
- Add full-path fault adapters for late VT failure, renderer failure, decoder recreation failure, and failure during replacement/seek/shutdown.
- Model Apple `requiresFlushToResumeDecoding` as its own scoped presentation recovery: one fence + flush/reprime per sink revision, then approved terminal/degraded outcome or a new presentation-graph/display-layer revision on recurrent video failure. The latter must prepare sinks, rebind both surface and PiP content source/controller, acknowledge new identities, and only then release the old borrows/graph.
- Replace the current `PlaybackCoordinator.handle(.decoderChanged)` → `PlaybackState.updateActiveDecoder(_:)` string-only projection. Preserve `PlayerDecoderStatus.isHardwareDecoded` and `.didFallbackToSoftware` as typed snapshot facts so a name such as “Software fallback” cannot be reclassified as hardware merely because it is nonempty.

### Stage 9 — Migrate A/V startup, buffering, synchronization, pause/resume, and sleep/wake

- Expand the already-authoritative startup/play-entry/drain slice from Stages 6–7 to buffering/starvation, ongoing clock/rate acknowledgment, pause/resume, drift correction, and A/V bound policy.
- Remove remaining `NativeAppleBackend.tick` policy and direct `MediaSession.setPlaying` decisions; clock and timeout arrive as explicit events.
- Preserve `AVSampleBufferRenderSynchronizer` as the initial native clock/presentation mechanism.
- Handle midstream video resolution/pixel-format/color changes and audio sample-rate/layout changes through format revision, old-batch fence/drain, format-description or converter recreation, and repreroll. Do not reuse the first-frame `SwrContext` across an incompatible change.
- Move the one resume-after-wake policy into `LifecycleReducer`; shell only reports notifications and executes display/power effects.
- Define and qualify how actual visible video and audible audio presentation time are measured before setting an A/V acceptance bound. Current `MediaSessionSnapshot.videoPTS`/`audioPTS`, later sampled by `AVSyncStabilityMetrics` in fixture tests, are submission horizons and must not be used as lip-sync proof.

### Stage 10 — Complete subtitle and track-switching migration

- Expand the already-authoritative minimal `SubtitleReducer` from Stage 4 to installed-source loading/processing/rendering, applied-delay consumption, font limits, and track-transaction integration; keep its existing clear/revision/final-rejection ownership. It still does not choose requested/effective selection or own the delay preference.
- Expand the minimal `TrackSelectionReducer` from Stage 7 from initial defaults to off/automatic/embedded/external selection plus prepare/commit/rollback for user track switching. Make `ControlReducer` authoritative for subtitle-delay preference and application results, forwarding only an internal applied-delay intent. `SessionReducer`/`LoadingReducer` do not retake track policy.
- Use distinct selection intents: audio `.automatic` versus a concrete stream (nil currently means default/auto), and subtitle `.off`, `.automatic`, concrete embedded, or external source (nil currently means off). Do not encode both domains as one ambiguous optional ID.
- Move external subtitle I/O off main actor. A `loadExternalSubtitle(select:false)` must never replace the selected live track; either load it as an unselected additional track if multi-sidecar support is explicitly approved, or return a deterministic unsupported result preserving today’s first-only behavior.
- Preserve an accepted external subtitle across audio-track replacement, including its full cue/font state and reported selection. Add a regression for the current reset/misreport path before changing authority.
- On every seek/replacement/track change, install the overlay fence and clear visibly through the control-priority main-actor endpoint first; perform source-specific libass invalidation separately. Embedded streamed events reset/repopulate, while full-file external tracks retain or deterministically reload cues. A blocked render/parse/font operation cannot delay the clear or shutdown fence.
- Define initial track “prepare” as owned codec-configuration copy plus decoder/libass resource creation—not undisclosed dual playback. After preparation, atomically advance track/generation and perform a replacement seek/preroll while retaining bounded old resources until new readiness; roll back with an explicit old-track generation/seek if commit fails. A future dual-pump optimization is separate work.
- Choose per-session libass library/renderer/track or an explicitly bounded shared font cache. Do not use process-randomized `Data.hashValue` as deterministic font identity; track/reset libass events and font leases, and prove bounded growth across distinct files.
- Prefer per-session libass library teardown initially because `ass_add_font` retains bytes inside `ASS_Library`; releasing an attachment source lease does not evict that font. Enforce owner-approved per-file font-count, per-font bytes, total font bytes, external-subtitle bytes/events, rendered-region count, and rendered pixel-byte limits. A shared cache is allowed only with bounded rebuildable library generations.
- Measure the prepare window with 4K/P010 video, multichannel audio, and attachment-heavy ASS. Inject cancellation/failure after each prepared component, prove the old effective track remains playable, and settle every partially created lease before accepting the transaction as rolled back.

### Stage 11 — Complete the reactive shell and persistence migration

- Replace mutable `PlaybackState` authority with `PlaybackUISnapshot`/`PlaybackViewStore`.
- Adapt `AppModel`, SwiftUI views, AppDelegate, Now Playing, PiP, persistence, fullscreen/display, file panels, drag/drop, and power assertions to the event/effect boundary.
- Remove direct lifecycle mutators and duplicate checkpoint/wake policy.
- Keep shell-only UI state local and preserve current UI/product behavior through compatibility tests.

### Stage 12 — Remove obsolete native orchestration and make the new native path default

- Delete migrated policy/locks/timer/snapshot polling from `MediaSession` and `NativeAppleBackend`; retain only executor mechanisms under production names rather than `POC` names.
- Remove transitional `PlayerBackendEvent` conversion and shadow comparison.
- Make the new native runtime the default after full automated and physical qualification, while preserving one release rollback to the immediately prior native build—not a new dual runtime architecture.
- Update authoritative architecture, behavior matrix, diagnostics, and qualification reports.
- Keep the broad native-parity freeze through this qualification gate; only then resume parity work against the single authoritative core/runtime path.

### Stage 13 — Remove legacy mpv/OpenGL and finalize native-only packaging

- After native reducer, deterministic-race, fixture, stress/sanitizer, physical, package/sign/notarize, and rollback-window gates pass, remove `CMpv`, `LegacyMpvBackend`, `Mpv*`, OpenGL, backend selection/preference/factory, mpv bootstrap/copy scripts, and bundled mpv dependencies.
- Switch `build-app.sh` to the qualified native FFmpeg/libass dependency closure and assert no mpv/OpenGL loader dependency in `verify-app.sh`.
- Remove the migration switch and compatibility protocols that exist only for dual backends.
- Do not introduce a Metal/libplacebo or cross-platform path as part of closeout.

Fuzz/model tests expand at every stage, not after stage 13. The later stages merely increase which real executors are compared against the model.

## 15. Tests and acceptance criteria for every stage

The exact commands can evolve, but no stage is complete on unit tests alone. At
the baseline the runner was `Scripts/run-native-poc-qualification.sh`; the
current runner is `Scripts/run-native-qualification.sh`. Architecture checks,
production build, `Scripts/verify-app.sh`, and relevant manual gates remain
cumulative. The baseline Xcode license/toolchain issue was resolved before the
2026-07-20 completion run.

The numeric latency, synchronization, and memory values below are **provisional candidate gates** drawn from the then-untracked `Documentation/MpvReferenceAnalysis/TEST_FIXTURE_PLAN.md`, not facts established by the planning-baseline build. Stage 0 was to capture baselines; each future threshold still must be defined against observable output rather than submission counters and approved for supported hardware before it can block release.

| Stage | Required automated tests | Native/product qualification | Acceptance and rollback boundary |
|---|---|---|---|
| 0. Honest baseline | Run all five current test targets with generated fixture manifest present; make missing required fixtures fail and optional gates explicitly report skipped; run architecture check and diff/package checks. | Full current qualification script, ASan/TSan standalone stress, 12+ reopen/leak sample, production app build/verify/sign dry run where available; archive command/tool/library versions and current semantic traces. | No behavior-affecting refactor begins until baseline is reproducible or each known failure is recorded. Rollback is current HEAD/native build and the archived traces. |
| 1. Pure core | Unit tests for every ID/time/failure/state/event/effect DTO; encode/decode/version rejection; transition determinism; duplicate/stale disposition; lease cleanup; invariant checker self-tests; seeded generator and shrinker self-tests. Construct semantically equal states/ledgers with shuffled `Set`/dictionary insertion histories and require identical sorted effects, replay bytes, and digests. Architecture test rejects AppKit, SwiftUI, Observation, AVFoundation, VideoToolbox, CFFmpeg, CLibass, Dispatch, `Task`, `Timer`, `Date`, and wall-clock APIs from the pure target. | Existing production/native suite remains byte-for-behavior unchanged. | Same initial state plus same ordered events must yield byte-canonical equal transitions/replay on repeated runs, independent of unordered-container insertion order. New target has no production authority. Delete the new target to roll back. |
| 2. Shadow capture | Adapter tests for every current `PlaybackCommand`, `PlayerBackendEventPayload`, native callback/snapshot fact, and platform notification; journal round-trip; snapshot comparison with documented mismatch categories; no shadow effect can reach runtime. | Replay traces for launch, single-file existing/new playlist open, multi-file natural sort, directory-precedence open, folder restore selection, play, pause/resume, all seeks, EOF/playlist, track/subtitle, sleep/wake, display/fullscreen, replace, stop, shutdown. Measure bounded journal overhead. | Every required flow is observable and replayable; unexplained state divergence is zero. Disable/remove shadow event feed to roll back; playback output is unchanged. |
| 3. Driver/coarse adapter | Mailbox total-order tests, no reducer reentrancy, effect-ID duplicate rejection, snapshot revision monotonicity, terminal command rejection, persistence completion identity, stale event cleanup, current coordinator compatibility tests. | Existing native fixtures/product flows through the event loop; compare current and new published UI snapshots. | There is one production command/result entry path for the migrated slice and exactly one owner per decision. Developer flag returns to pre-driver native coordinator. |
| 4. Fences/leases | Deterministic barriers: block old video/audio enqueue, rate request, libass packet, subtitle overlay, EOF, and late VT failure immediately before commit; seek/replace/stop; release; assert rejection or flush ordering. Fail/fence at every index of N-item decode/enqueue batches and assert exact consumed-prefix/remainder/output custody with no duplicate. Hold either renderer not-ready forever, then issue seek/replace/stop/shutdown; control/release finishes without readiness. Inject late readiness and late/duplicate/dropped flush before commit/main-actor hop/mutation. Test subscription cancel acknowledgment without original terminal, original terminal then late callbacks, old surface/display/PiP IDs, A/V membership permutations, release during borrow/C call, `.shuttingDown`, `.terminated`, tombstone disposal, and release conservation. | Existing rapid seek/replacement plus 50 mixed A/V↔video-only↔audio-only replacements; PiP active across replacement, renderer recreation, surface detach/reattach, display change, stop, and shutdown with late old-controller callbacks. At fair-delivery quiescence: zero live workers, leases, borrows, subscriptions, and callbacks; provisional RSS candidate is within the larger of 10% or 32 MiB of warmed baseline with no monotonic slope. | No stale identity may commit a sample, subtitle event, rate, platform mutation, failure, or EOF. Data readiness cannot block control. Batch occupancy/custody is conserved exactly. Cancel-request acknowledgment cannot close the original subscription. Permanent release/subscription-terminal loss remains explicit nonquiescent timeout; it cannot satisfy the zero-ledger gate. Roll back the commit-fence/registry adapter as one slice; do not proceed to seek authority without it. |
| 5. Input/demux | Cancellable blocked-open/read tests; cancel-vs-success at every `avformat_open_input`/probe/read/seek boundary; late cancel A while call B is active; replace during probe; demux-flush acknowledgment; malformed timestamps; queue credit/control-priority properties; exact-once release; quarantine worker/byte cap exhaustion. | Generated stream/codec/catalog/chapter/attachment fixtures; corrupt/truncated input; blocked custom AVIO; main-actor responsiveness; repeated open/replace/close under sanitizers with uncancellable-call shim. | Open/probe/read never block the main actor; stale cancellation cannot abort a newer C call; stop/replace/shutdown interrupts and joins or explicitly quarantines within strict caps; selected streams match documented policy in 100% of fixtures. Switch input executor back to coarse native adapter to roll back. |
| 6. Seeking | Model matrix for relative/exact/preview, duplicate/reordered/dropped completions, preview storm/final exact, seek failure/timeout, unknown duration, invalid PTS, EOF during seek, seek during recovery, track/shutdown during every phase. Arithmetic tests for video floor, sample-accurate audio trim, and displayed-image policy. | CFR/VFR/long-GOP/non-zero and negative start/near-EOF/unknown-duration fixtures; existing rapid-seek and preview tests; compare with pinned mpv oracle; inspect layer/PiP through retained same-media versus removed replacement frames. | Exact video lands on the same eligible frame as mpv or within one frame with reason recorded; no audio sample before normalized target is enqueued; final exact always wins; one authoritative transaction; zero stale commit; prior-file pixels are never visible after replacement authority changes. Roll back `SeekReducer` as a vertical slice while retaining stage-4 fences. |
| 7. Load/EOF/replacement | No-playing-before-preroll model tests for A/V, audio-only, video-only; sink-capacity true with zero commits; `.none` versus unknown-PTS submission; all drain permutations; clean EOF versus read-failure-after-valid-data; duplicate/stale EOF; once-only completion; replacement late callbacks. Add current playlist/open/restore, active-item, same-item-after-EOF, and Stop → Play-from-zero tests. | Delayed-frame/resampler-tail, unknown-PTS, zero-frame, truncated-after-valid-data, last-frame/last-tone, pause final drain, renderer flush/failure, audio route, origin/duration disagreement; A/V membership permutations, 50 replacements, playlist/resume tests. Product EOF is never earlier than final required presentation minus one quantum; provisional candidate is normally within 500 ms after accepted drain. | Loaded/configured/prerolled/playing are distinct; sink backpressure alone never satisfies preroll; unconfirmed/timeout/truncated outcomes cannot consume clean completion; playlist advances once; replacement removes prior-file layer/PiP pixels; current replay/reload and playlist-construction semantics remain stable. Roll back session/EOF reducers together. |
| 8. Recovery | Fault matrix for VT failure at configure/decode/drain and every batch item, late old recovery, software recreation, `requiresFlushToResumeDecoding` first/recurrent/failed flush, full graph/display-layer replacement with PiP active, retry exhaustion, seek/replacement/shutdown during recovery. Assert executor facts only, lineage-keyed budgets, partial-batch conservation, and typed hardware/fallback status. | Full-path VT and renderer fault shims plus software fixtures, rapid seek/replacement, corrupt media, PiP-active graph replacement/rebind with old callbacks, sanitizer/leak run. | Recovery uses a new generation, never commits old/duplicated output, never worker-seeks, and does not replenish fallback budget on decoder recreation. First requires-flush gets one reprime; recurrent video failure either fails per policy or proves surface+PiP rebind to a new graph/layer before old release. UI reports fallback accurately. Roll back recovery reducer while keeping scoped failures. |
| 9. A/V sync/lifecycle | Virtual tests for sink-can-accept with zero samples, delayed effective-rate observation, pause/fence preempting pending nonzero rate, stale rate, starvation/drift, lifecycle/platform identity, and video/audio format changes during seek/drain/recovery with old-format batches queued. Reject submission-PTS-only evidence. | Long H.264/HEVC/VFR plus audio/video-only; midstream resolution/pixel-format/color and audio rate/layout fixtures; VT→software format change; qualify visible/audible timing; physical lifecycle/routes/displays; power checks. | Playing requires committed current-generation preroll and matching observed effective rate. Old-format output never commits; converter/format descriptions recreate and repreroll within measured bounds. Once approved, provisional A/V candidate is within 50 ms/no excursion over 100 ms outside declared windows. Roll back synchronization/lifecycle authority together. |
| 10. Subtitles/tracks | Old embedded packet/render/overlay/clear after seek/track/file; immediate clear while render/parse/font work is blocked; external full-file cues after forward/back seek; embedded spanning-cue repopulation; audio automatic vs subtitle off; external subtitle across audio replacement; first-sidecar selected plus later `select:false` deterministic result; rapid switch; prepare cancellation every component; partial leases. | SRT/ASS embedded/external, multiple matched sidecars, many unique and oversized fonts, oversized/pathological subtitle files, region/pixel-output limits, heavy 1080p/4K, 4K/P010 plus multichannel audio/attachment-heavy ASS prepare rollback, resize/rotation/PiP. | Visible clear is control-priority and precedes new output; external cue sets survive/reload correctly; selection/first-only capability is truthful; failed preparation preserves old playability; every partial lease settles; font/file/event/region/pixel and overlap growth stay inside approved hard limits. Roll back subtitle/track reducers independently where possible. |
| 11. Reactive shell | Snapshot/adapter tests for every current `PlaybackState` semantic field and established name, per-row live/persisted playlist progress, capability reads, clear-history, and reset-all-video-adjustments; view tests prove lifecycle is command-only; Now Playing, restore/checkpoint, PiP, error dismissal, chrome, fullscreen/display, termination, delayed publication. Static search rejects direct lifecycle/coordinator side methods. | Full manual product checklist after removing legacy-only items or marking unsupported; Finder/drag/file/folder restore, playlist progress, settings/command enablement, history clear, video reset, window/fullscreen, lifecycle, Now Playing/PiP, persistence migration. | Existing user-visible native behavior is preserved unless an owner-approved semantic change is recorded. No shell object or compatibility read surface owns core lifecycle/policy. Roll back to snapshot adapter while preserving reducer/runtime state. |
| 12. New native default | All core fuzz regressions, extended seeds, every native fixture/fault/barrier test, all product/shell tests, architecture imports/ownership checks, no transitional policy symbols, replay compatibility migration. | Full qualification script, ASan/TSan, 50+ replacement/seek stress, memory slope, all physical release matrix, production build/package/sign/notarize, upgrade/rollback rehearsal. | New runtime is default; zero live playback workers/leases/subscriptions/callbacks after every close; no unexplained differential regressions; broad parity remains frozen until this gate closes; old native orchestration can be restored only by rolling back the release/commit, not by sharing authority. |
| 13. Native-only closeout | Build graph asserts no `CMpv`, `LegacyMpvBackend`, `Mpv*`, `PlayerBackendKind`, dual-backend preference, or OpenGL reference; preference migration tests; native dependency-closure and loader-path tests. | Verify release app on clean supported macOS machines, code signature/notarization/staple, Finder handler, update/rollback, all physical playback gates. | Package has only approved FFmpeg/libass/native Apple dependencies; no mpv/OpenGL runtime fallback; compatibility/migration switch removed. Rollback is the prior qualified release, not partial source resurrection. |

Additional stage-independent acceptance rules:

- a changed policy path gets a pure core test, a fault/reorder test, and a real-executor test where mechanism matters;
- a fixed fuzz failure lands with its minimized replay fixture;
- an effect result is not “tested” by a sleep; tests wait on a scoped semantic completion or virtual deadline;
- historical report counts are never substituted for current execution;
- unsupported media/behavior is reported before misleading success;
- shell/product and packaging tests remain cumulative even when their implementation did not change in the current stage.

### 15.1 Cross-stage performance and responsiveness gates

The deterministic control plane must not turn every frame into reducer traffic or hide a playback regression behind stronger correctness tests. Stage 0 records warmed baselines and confidence intervals; stages 3–12 compare the same fixtures, machine power mode, display, and release build. Thresholds are owner-approved after measurement, not invented from current submission counters.

| Metric | Required definition and instrumentation | Gate use |
|---|---|---|
| Open/start latency | Command accepted → input opened/probed → first eligible sample committed → first actually visible frame and first audible sentinel where measurable. Record each segment separately. | Prevent main-actor/open regressions and distinguish demux, decode, preroll, and sink latency. |
| Seek/preview latency | Seek command → fence installed → demux landing → first eligible commit → first visible/audible output; include p50/p95/p99, preview cadence, final-exact latency, and stale work rejected. | Compare reducer path with the Stage 0 trace and pinned mpv oracle without conflating landing with presentation. |
| Presentation quality | Observable frame delivery/cadence/jitter/drops, audio underruns, renderer failures/flushes, and qualified audible-versus-visible A/V error. | Release gate for long CFR/VFR, 4K/P010/HDR, audio-only, and video-only fixtures. Submission PTS is diagnostic only. |
| Event-loop cost | Events and effects per second, maximum and percentile reducer duration, mailbox depth/high-water, time-to-process control events under a saturated data plane. | A full data queue or frame storm must not delay seek/stop/shutdown beyond the approved control deadline. |
| Memory/resources | Live and high-water leases and bytes by executor, packet/frame media duration, worker/subscription counts, warmed RSS slope, track-prepare overlap. | Prove bounded queues, no monotonic reopen/replacement growth, and zero acknowledged ledger at fair-delivery quiescence. |
| UI responsiveness | Main-actor stall and frame/hang instrumentation during open/probe, external subtitle load, rapid seek, track prepare, replacement, and shutdown. | No blocking FFmpeg/libass/file I/O or readiness wait on the main actor; owner-approved percentile budget. |
| CPU/energy | Release-build CPU, wakeups, energy impact, hardware/software decode mode, and paused-idle consumption for long 1080p and 4K/P010 playback. | Catch excess batching/journaling/callback traffic and accidental loss of VideoToolbox. |
| Journal overhead | Playback with capture disabled, bounded summary mode, and full test capture; compare CPU, allocations, mailbox depth, and I/O. | Disabled production capture must be near-baseline within an owner-approved budget; full artifacts remain opt-in. |

Every performance result records toolchain, FFmpeg/libass versions, hardware, macOS, display/audio route, power state, media fixture hash, backend mode, and whether visible/audible timing is measured or inferred. A faster but semantically incorrect run never passes; a correct but materially slower run blocks the relevant authority stage until accepted or fixed.

## 16. Risks and rollback points

| Risk | Mitigation and evidence gate | Rollback point |
|---|---|---|
| A giant root reducer recreates `MediaSession` in value syntax. | One primary reducer per event, owned state slices, typed internal intents, small fixed root coordinator, effect conflict keys, per-file size/review checks. | Stage 1/2 has no authority; split a reducer before enabling its slice. |
| Per-frame reducer traffic becomes a CPU or latency bottleneck. | Bounded batch grants/leases, metadata summaries, performance counters, stress profiles. Never move pixel/PCM bytes into events. | Increase safe batch size or return a data-pump slice to the prior executor while retaining identity fence. |
| Core is deterministic but physical sinks still accept stale work. | Mandatory serialized presentation and subtitle commit fences tested with exact barriers before seek/replacement migration. | Do not enable stage 6/7; roll back stage 4 as one adapter. |
| Apple renderer drain cannot be proven cleanly. | Define conservative evidence using submission horizon, clock crossing, status/sink-capacity observations, tolerances, and physical fixtures; represent timeout/unconfirmed explicitly. | Keep current native EOF policy behind stage-7 switch; do not claim renderer-drained EOF or advance automatically on unproven state. |
| FFmpeg cancellation leaves shutdown non-quiescent. | AVIO interrupt token, blocked-open/read test, control-priority cancellation, tracked worker joins. | Do not enable new shutdown authority or native default until stage 5 passes. |
| Track preparation doubles memory or cannot roll back. | Bounded dual leases, prepare/commit window, stress/memory threshold, release old resources immediately after commit. | Keep current destructive switch temporarily; do not enable new switch until preparation passes bounds. |
| Recovery policy changes picture/codec behavior while architecture moves. | Preserve existing preferred VT then software behavior initially; typed fault adapter and mpv/fixture comparison; one retry budget. | Switch only recovery slice to prior native policy. |
| Timestamp model or origin normalization changes resume/seek semantics. | Explicit valid/unknown/invalid rational time, fixture matrix, persisted `TimeInterval` conversion at boundary, differential traces. | Keep stored schema and old timeline adapter; migrate data only after comparison. |
| Main-actor/Apple API constraints conflict with executor design. | Keep AppKit/required AV calls in `PlatformExecutor` or a narrow main-actor bridge; the commit fence owns serialization even if its final call hops to main. | Retain current presenter wrapper behind the fence while refining executor placement. |
| Event/effect/replay schema churn makes old failures unusable. | Versioned DTO, migrations/read-only decoders, canonical fixtures, stable error codes. | Continue reading prior schema; never silently reinterpret it. |
| Journal leaks user paths or grows without bound. | Redacted source IDs, bounded ring journal, opt-in full artifacts, explicit export location/retention. | Disable full production capture; pure tests remain unaffected. |
| Two authorities coexist during migration. | Shadow core emits no effects; each vertical slice has a single feature ownership flag and static checks; remove old policy after qualification. | Flip the entire slice to the previous native owner, never blend per-event decisions. |
| Native parity work creates merge conflicts and duplicate behavior. | Feature freeze except baseline correctness/security/release blockers; rebase behavior scenarios into the core tests. | Defer parity feature rather than implement it twice. |
| Legacy removal happens before native deployment confidence. | Final removal only after reducer/native/stress/physical/package gates and a qualified prior-release rollback artifact. | Ship/restore prior release. The target architecture itself still remains native-only. |

The critical rollback rule is to retain the immediately previous **native** vertical slice until the new one is qualified. mpv may remain in the shipping tree temporarily because it exists today, but the new core never treats mpv as its recovery executor and never grows a generic multi-backend policy.

## 17. Estimated code churn by module

These are planning ranges for gross lines added/meaningfully changed/deleted, not schedule estimates or final net growth. Current Swift sizes are approximately: Core 1,835 lines, Playback contracts 292, Player 3,143, App 2,296, native implementation 4,126, and tests 2,002. `MediaSession` (689), `NativeAppleBackend` (695), `PlaybackCoordinator` (853), and `PlaybackState` (298) contain most orchestration churn.

| Area | Estimated gross churn | Character of change |
|---|---:|---|
| New `SuperplayrPlaybackCore` production target | 2,500–4,000 lines added | IDs/time/failures, state slices, commands/events/effects, reducers, coordinator/planner, invariant checks, snapshot projection, replay DTOs. This range assumes explicit types rather than a generic framework. |
| `SuperplayrCore` | 300–700 lines changed; roughly 200–350 eventually deleted/replaced | Track/source boundary adaptation, command relocation, snapshot-facing models, persistence contracts, removal of mutable `PlaybackState` authority and backend preference. |
| `SuperplayrPlayback` | 200–400 lines changed/deleted | Transitional event/backend bridge, then removal of dual-backend protocol/selector/event gate; retain/adapt only capability/surface values that remain useful. |
| `SuperplayrPlayer` excluding legacy deletion | 700–1,200 lines added/changed; 700–1,000 old orchestration lines removed | Split `PlaybackCoordinator` into event loop, runtime composition, view store/facade, and shell adapters; expand architecture validation. |
| Legacy mpv/OpenGL code | About 1,960 Swift lines plus C/package/script glue deleted | `LegacyMpvBackend`, surface, `Mpv*`, `CMpv`, OpenGL, selection and package closure. Deletion occurs only at stage 13. |
| Native playback production | 3,000–5,000 lines added/changed; 1,200–1,600 orchestration lines removed | Executor/lease/fence extraction, cancellable input, batching/budgets, typed decoder/presenter/subtitle results, drain/recovery mechanics; removal of backend/session policy/timer/locks. |
| C shims | 100–300 lines changed | AVIO interrupt/cancellation hooks, stable metadata/status/error accessors, optional test fault hooks. Avoid broad owned rewrites of FFmpeg/libass. |
| `SuperplayrApp` | 400–900 lines changed | Snapshot/command wiring, AppModel split, Now Playing/system/AppDelegate adaptation, removal of direct state mutation; visual layout should see low churn. |
| Tests, model runtime, replay fixtures | 4,000–7,000 lines added/changed | Pure reducer/model/fuzz/shrinker/replay, exact barrier/fault executors, current product compatibility, real media integration, package checks. Tests are expected to be the largest net addition. |
| Fixture, qualification, packaging scripts | 500–1,000 lines changed/added | Manifest and required-fixture gates, new generated edge fixtures, fault/replay runners, native package dependency assertions, mpv removal. |
| Architecture/reference/qualification documentation | 500–1,000 lines changed/added beyond this plan | Authoritative implemented architecture, behavior provenance/status matrix, replay schema, acceptance evidence, historical-report labels. |

Expected total gross churn is approximately **12,000–21,000 lines** across production, tests, scripts, and documentation, with roughly **3,000–4,500 lines deleted** by removing old native orchestration, mutable authority, and legacy mpv/OpenGL. The final production net should be much smaller than the gross range; tests and replay infrastructure account for much of the addition.

This is large enough to require vertical stages and ownership gates, but not evidence for a big-bang rewrite. The current low-level native components and fixtures materially reduce implementation risk.

## 18. Questions and decisions requiring owner approval

| Decision | Recommended default | Why owner approval matters |
|---|---|---|
| Refactor timing | Approve a broad native-parity freeze and perform the core refactor now, allowing only baseline correctness/security/release blockers. | Parallel parity work otherwise has to be implemented or debugged in both orchestration models. |
| Pure module boundary | Add `SuperplayrPlaybackCore` as a new target depending only on required `SuperplayrCore` values. | This is a durable module/API choice and slightly increases target count, but gives enforceable framework independence. |
| `update` return type | Return `PlaybackTransition { disposition, effects }`, not only `[PlaybackEffect]`. | Stale/duplicate/invalid disposition and cleanup-only effects are first-class replay evidence. |
| Timestamp representation | Use explicit rational `valid/unknown/invalid` values in core and convert to/from `TimeInterval`/FFmpeg/CMTime only at boundaries. | This may expose current unknown-duration/start-time behavior changes and affects replay schema. |
| Initial A/V policy | Preserve `AVSampleBufferRenderSynchronizer` as the clock/presentation mechanism; extract policy without retuning it until tests are in place. | Architecture and playback tuning should not change simultaneously. |
| Presentation drain contract | Start with explicit submission horizon + synchronizer-clock + renderer-status/capacity facts and the provisional `TEST_FIXTURE_PLAN.md` tolerances; treat unknown/unconfirmed drain as explicit failure/timeout. | Apple lacks a simple universal drain callback, so release semantics and timeout UX need a product decision after an implementation spike. |
| Displayed image during seek | Preserve current same-media seek frame retention initially; always remove old pixels for replacement, stop, and shutdown, including PiP. | Retaining a frame reduces blanking but must be an explicit UX policy and must never cross media authority. |
| Preview behavior/cadence | Core owns latest-wins/final-exact priority and a virtual debounce; preserve roughly current visible cadence initially. | Preview quality versus CPU/latency is product behavior; UI throttling alone cannot be correctness policy. |
| Same-item and restart semantics | Preserve active-item selection as resume/no reload, same-item selection after EOF as reload, and Stop → Play as selected-item reload from the beginning. Consider fixing the zero-overwrite checkpoint only as a separate UX/persistence change. | These are source-confirmed behaviors but lightly tested; changing them while extracting session authority would create an accidental UX change. |
| Playlist open/restore semantics | Preserve existing-entry reuse, folderless singleton/multi-file natural sorting, directory precedence, and folder restore by `lastWatchedFile`/first item during refactor. Decide separately whether stored `playlistIndex` should be honored. | These rules are source-confirmed and shape restoration, but some may be accidental; the architecture migration should not silently choose new product semantics. |
| Track selection semantics | Make audio automatic/default and subtitle off/automatic/embedded/external explicit. Treat preserving external subtitle state across audio replacement as a correctness requirement, while recording the current reset/misreport behavior as the baseline defect. | A shared optional track ID cannot represent today’s different nil meanings, and the external-subtitle loss is user-visible state corruption rather than an architectural preference. |
| Multiple external sidecars | Preserve current first-matched-only behavior during the architecture migration; specify later `select:false` requests as deterministic unsupported. Add multiple unselected external tracks only as approved post-Stage-12 parity. | Current restore loops all sidecars but the native backend rejects every later one. Treating them as already loaded would be a false baseline; fixing it adds product capability. |
| Track-switch atomicity | Permit a bounded prepare/commit overlap so a failed new decoder/track can roll back to the old playable path. | This temporarily increases memory and resource count; the owner must accept bounded overlap or choose a visible destructive switch. |
| Recovery budget/degraded playback | Preserve one VT→software fallback per media-session/video-stream lineage; for renderer `requiresFlush`, allow one flush/reprime per sink revision before recreation/failure. Decide separately whether audio failure may continue video-only. | Degraded modes and renderer recreation are user-visible product policy; decoder revisions created by recovery must not replenish a budget. |
| Queue budgets | Keep current item capacities as an initial ceiling, then add measured byte/time limits and tune from fixtures. | Exact memory/latency budgets affect throughput and low-memory behavior. |
| Stuck-worker quarantine | Set strict application/session caps for timed-out input/decoder workers and retained bytes; reject further loads and surface a diagnostic once exceeded. | Per-input queues preserve responsiveness but cannot turn uncancellable protocols into unbounded threads/resources. |
| Subtitle hard limits | Prefer per-session libass libraries and approve font count/bytes, subtitle file/events, rendered region, and pixel-byte ceilings from qualified fixtures. | `ass_add_font` retains data for the library lifetime, and pathological ASS/fonts can defeat ordinary queue limits. |
| Performance thresholds and A/V observation | Establish Stage 0 baselines, qualify actual visible/audible instrumentation, then approve hardware-specific latency, A/V, memory, CPU/energy, mailbox, and UI-response gates. | The candidate 50/100 ms, 500 ms, and RSS values in the reference analysis are useful starting points but are not current qualification facts. |
| Sleep/wake resume semantics | One core-owned resume intent; preserve “resume only if playing before sleep.” | Current coordinator/backend duplicate calls can mask edge semantics; this makes behavior explicit. |
| Restore `wasPaused` behavior | Preserve current auto-play during refactor unless the owner explicitly elects to honor persisted paused state. | Changing it while moving persistence would conflate architecture with UX. |
| Shutdown timeout | Prefer continued cleanup with visible structured timeout and app-termination escalation policy; never call a timed-out runtime quiescent. | macOS termination cannot wait forever, but force-exit semantics and diagnostic capture are product/release decisions. |
| Native-only capability scope | Publish a list of legacy-only commands/features that are intentionally unsupported versus required before mpv removal (filters, screenshots, output-device control, network sources, etc.). | The target does not include a hidden mpv fallback, so omissions must be explicit release decisions. |
| Replay privacy/retention | Redact absolute sources by default, keep a bounded in-memory journal, and export full artifacts only explicitly or in fixture CI. | Production replay can otherwise expose local filenames and grow unbounded. |
| Reference analysis adoption | **Resolved:** imported unchanged at `773586f`; preserve its `fbdc699` source baseline and external pins while layering current status explicitly. | The analysis is now tracked, but remains a dated source study rather than release evidence. |
| Native dependency reproducibility | Decide whether release FFmpeg/libass builds become pinned artifacts rather than system-library discovery. | Differential evidence and packaged behavior are harder to reproduce when Homebrew/system versions drift. This can be a separate release-engineering change. |
| Physical/CI matrix ownership | Assign supported Apple Silicon/macOS/display/audio hardware and required release gates. | Several current manual qualification items remain open and cannot be replaced by reducer tests. |

At the planning baseline, none of these questions blocked writing the pure model
or shadow journal. The production choices made for the completed authority path
are reflected in `FCIS_COMPLETION_MATRIX.md` and current source. Oracle
tolerances, dependency reproducibility, and full physical-matrix ownership
remain next-phase or release decisions where the current evidence does not
resolve them.

## 19. Final recommended implementation order

The numbered list below is the original dependency order. Its production
authority outcome is complete through `6825c6b`, including native-only package
closeout. It remains useful as an audit trail, not as the current backlog.

The recommended order is dependency-driven:

1. Establish a current, fixture-backed, packaged native baseline and freeze broad parity work.
2. Add the pure target, explicit identities/time/failures, state slices, transition disposition, invariants, model runtime, and replay/shrink format.
3. Journal the entire existing command/callback flow in shadow mode.
4. Make the serialized event loop, session/operation/effect identity, cleanup semantics, and resource ledger real.
5. Install presentation and subtitle final-commit fences before moving any generation-changing policy.
6. Extract cancellable open/probe/demux and bounded batch grants.
7. Move relative/exact/preview seeking and generation invalidation.
8. Move loading/preroll distinctions, renderer-drained EOF, file replacement, and once-only playlist advancement.
9. Move typed recovery and VideoToolbox/software fallback policy.
10. Move A/V startup, clock, pause/resume, buffering, synchronization, and sleep/wake.
11. Move subtitle lifecycle and atomic track switching.
12. Replace mutable UI authority with the reactive snapshot shell and finish persistence/Now Playing/platform adaptation.
13. Remove old native orchestration, qualify the new native runtime as default, and publish the implemented architecture/evidence.
14. Remove legacy mpv/OpenGL/backend selection and finalize native-only packaging only after the full automated and physical gates pass.

### Decisive recommendation

**Completed:** the refactor was undertaken before further native playback
parity, and the functional core is now the production behavior authority.

At `fbdc699`, the architecture was not sufficient: observable state gating did
not guarantee physical sink isolation, EOF was not presentation-drained,
recovery policy lived in a decoder worker, and shutdown could not prove
quiescence. Those baseline findings motivated the completed authority migration;
they are not current architecture claims.

The implementation followed the intended non-big-bang direction while adapting
the exact stage boundaries and acknowledgement granularity. The current backlog
is the mpv-oracle/differential sequence in
[MpvReferenceAnalysis/TEST_FIXTURE_PLAN.md](MpvReferenceAnalysis/TEST_FIXTURE_PLAN.md):
freeze the run contract, make fixtures self-verifying, land semantic
load/seek/EOF comparisons, translate deterministic fault scenarios, then
calibrate and execute presentation/physical gates. Do not claim those unrun
fixtures or devices complete, and do not reopen the completed authority or
native-only dependency decisions to perform them.
