# Recommended native refactor

Plan baseline: Superplayr `fbdc699627bebf4298a630004ca31a31b0ec5df4`,
2026-07-19.

Implementation status: **FC/IS authority migration completed** at
`6825c6b90c9bfdcd3f80391c177edc22a2523513` on 2026-07-20. The plan below is
retained as the design and acceptance rationale; future-tense statements are
not evidence that the authority migration remains open. Current ownership and
verification are recorded in
[FCIS_COMPLETION_MATRIX.md](../FCIS_COMPLETION_MATRIX.md) and
[NATIVE_PLAYBACK_QUALIFICATION.md](../NATIVE_PLAYBACK_QUALIFICATION.md).

## Decisive recommendation

The 2026-07-19 recommendation was: **refactor the native architecture before
adding more features.** That recommendation has been implemented.

Retain:

- FFmpeg for container parsing, probing, packet extraction, codec decoding,
  text subtitle conversion, bitmap subtitle decoding, swresample, and necessary
  software pixel conversion;
- VideoToolbox as the preferred hardware decoder through FFmpeg;
- `AVSampleBufferRenderSynchronizer` with Apple audio/video sample renderers as
  the initial presentation route;
- libass for ASS/SSA parsing, shaping, effects, font fallback, and raster masks;
- the useful backend-neutral product seam for playlist, persistence, commands,
  and surface hosting.

Remove after acceptance:

- legacy libmpv engine/runtime fallback;
- OpenGL presenter and linker dependency;
- dual-backend selection/preferences/factories and legacy compatibility code.

Do not build Direct Metal yet. The missing essential behavior is player-core
coordination; a new renderer would leave those gaps intact.

## 1. Proposed module boundaries and implemented interpretation

The diagram below is the baseline proposal. The completed implementation
preserves its ownership direction through `SuperplayrPlaybackCore`,
`PlaybackRuntimeDriver`, `NativePlaybackRuntime`, and `PlaybackViewStore`.
Tightly coupled native work is sometimes one aggregate effect rather than a
separate public effect for every internal barrier. This is intentional when the
acknowledgement states what it proves, carries the originating authority/effect
context, represents failure/cancellation, and remains fault-injectable.

```text
PlaybackCoordinator (product/UI; existing neutral responsibilities)
    |
    v
NativePlaybackSession actor  <---- CapabilityProvider / EventJournal
    |
    +-- MediaSourceOpener
    |     `-- cancellable FFmpeg open/probe + source identity
    |
    +-- DemuxPipeline actor
    |     `-- AVFormatContext + TrackCatalog + packet queues
    |
    +-- TimelineMapper
    |
    +-- VideoDecodePipeline actor
    +-- AudioDecodePipeline actor
    +-- SubtitleDecodePipeline actor
    |
    +-- PresentationSession actor
    |     +-- Apple video renderer adapter
    |     +-- Apple audio renderer adapter
    |     +-- synchronizer/clock facade
    |     `-- presentation lease + drain observer
    |
    +-- SubtitleRenderer
    |     +-- libass renderer
    |     +-- bitmap region model/compositor
    |     `-- viewport/HDR composition policy
    |
    `-- RecoverySupervisor
```

### `NativePlaybackSession`

The only authority for state transitions. It owns current source, epoch,
operation generation, selected tracks, desired pause/rate, active capabilities,
terminal outcome, and system sleep/wake recovery intent. Workers and the
product layer report intent/results; they do not independently seek, flush,
change rate, resume after wake, or publish product EOF.

### `MediaSourceOpener`

Runs off-main, owns an FFmpeg interrupt token, produces staged metadata, and
can be cancelled by replace/stop/shutdown. It preserves source identity and
returns an unopened error without mutating the active session.

The current `@MainActor` `PlayerBackend.load(_:) throws` contract is synchronous.
The refactor must either make load an async command/result operation or keep the
surface method nonblocking and return an operation identity whose completion is
reported by typed events. FFmpeg open/probe construction must never remain
inside the synchronous main-actor call.

### `DemuxPipeline`

The sole accessor of `AVFormatContext` after open. It owns track catalog
updates, packet read/seek/flush, attachment extraction, and per-track packet
queues. Its API returns typed packet/would-block/EOF/failure outcomes.

### `TimelineMapper`

Maps original stream/container time to a non-negative player timeline. It
retains `mediaOrigin`, original PTS/DTS, known/unknown duration, inferred values,
and discontinuity segments. It is shared by demux, decoders, seek, subtitles,
presentation, chapters, resume, and diagnostics.

### Decode pipelines

Each active track owns its FFmpeg codec context, frame objects, conversion
state, and `TrackRevision`. Contracts are explicit: configure, consume, drain,
flush, reconfigure, close. A decoder reports faults to the supervisor and never
initiates global recovery itself.

### `PresentationSession`

Owns the synchronizer and renderers plus one globally monotonic presentation
lease. Enqueue, flush, rate, auto-flush notification, renderer failure, drain,
and callback invalidation are serialized. Every commit validates the complete
epoch/generation/revision tuple while holding that serialization boundary. It
attaches only renderers belonging to active tracks: video-only sessions use the
Apple host-clock route, and audio-loss degradation removes the failed audio
renderer before the new presentation generation is primed.

### `SubtitleDecodePipeline` and `SubtitleRenderer`

FFmpeg converts supported text to ASS or decodes bitmap regions. libass renders
ASS. The scheduler owns delay and active-cue rebuilding; the compositor owns
viewport, bitmap placement, rotation, and HDR/EDR subtitle policy.

### `RecoverySupervisor`

Classifies typed faults and applies bounded, subsystem-scoped actions. It is a
policy object called by the session actor, not a worker-side exception handler.

## 2. Ownership of demux, decode, clocks, presentation, and subtitles

| Responsibility | Owner |
| --- | --- |
| Container/protocol/packet parsing | FFmpeg |
| Open/probe budgets, cancellation, user errors | `MediaSourceOpener` |
| Track catalog and selection policy | `NativePlaybackSession` + `TrackCatalog` |
| Packet cache/queue/backpressure | `DemuxPipeline` |
| Original-to-player time mapping | `TimelineMapper` |
| Codec implementation/reordering/drain primitive | FFmpeg |
| Hardware decode | VideoToolbox through FFmpeg |
| HW selection/fallback/recreation | `RecoverySupervisor` + video pipeline |
| PCM conversion/rematrix | FFmpeg/libswresample |
| Routine A/V source clock and sample scheduling | Apple synchronizer/renderers |
| Start, pause, seek, starvation, device change, EOF policy | `NativePlaybackSession` |
| Sample/pixel-buffer handoff lifetime | decode frame + `PresentationSession` lease |
| Text subtitle decode/conversion | FFmpeg |
| ASS shaping/rasterization/font fallback | libass |
| Bitmap subtitle decode | FFmpeg |
| Subtitle timing/delay/reset/viewport/HDR composition | Superplayr subtitle modules |

This preserves dependency ownership documented in
[DEPENDENCY_OWNERSHIP.md](DEPENDENCY_OWNERSHIP.md).

## 3. Queue and generation model

### Identities

Use three explicit, non-wrapping identities:

- `PlaybackEpoch`: changes for every opened/replaced source and presentation
  ownership swap;
- `OperationGeneration`: changes for seek, discontinuity, full repreroll, or
  global recovery within one source;
- `TrackRevision`: changes when one selected track/decoder/format is replaced.

Use `UInt64` with checked increment/precondition or UUID-like identity. Current
native `PlaybackGeneration` uses wrapping `Int &+=`, while the product
controller's generation uses wrapping `UInt64 &+=`; per-session reset is also
not sufficient. `PlaybackEpoch` must become the native counterpart of the
existing `PlayerSessionIdentity`, with one mapping/authority rather than a
second unsynchronized identity hierarchy.

Every packet, decoded frame/audio block, subtitle event, EOS stage, renderer
callback, fault, and event carries the applicable tuple. Stale data is rejected
at the serialized commit, not merely checked earlier in a worker.

### Queue ownership

```text
demux returns a caller-owned AVPacket reference
 -> packet queue owns that reference until decoder accepts or purge
 -> successful avcodec_send_packet may retain an independent internal ref
 -> decode pipeline releases its caller-owned packet reference
 -> decode pipeline owns AVFrame/output block
 -> presentation queue/lease owns until enqueue/drain contract releases
 -> Apple may retain sample/pixel buffer under framework contract
```

Queues have:

- count, byte, and media-duration budgets;
- high/low watermarks and explicit state (`open`, `draining`, `closed`,
  `aborted`);
- no ambiguous sentinel ordering;
- a separate priority control path so stop/seek cannot wait behind data;
- structured high-water/backpressure diagnostics;
- no arbitrary drop of reference packets;
- bounded decoded VideoToolbox surface retention.

Multiple buffered ranges remain an optional future `DemuxCache` implementation.
The initial local-file pipeline needs only current-range queues.

### Presentation commit

Conceptually, every sink operation is:

```text
presentationSession.commit(identity) {
    enqueue | flush | setRate | updateSubtitle | markDrain
}
```

Identity validation and mutation occur on the same executor. Old sessions cannot
change a new session's renderer, subtitle track, clock rate, failure, or EOF.

Replacement is an explicit transaction:

```text
request replacement -> revoke old epoch -> cancel/stop -> join old workers
                    -> destroy or detach old contexts/sinks
                    -> configure and start the new epoch
```

If distinct per-session sinks are prepared instead, the surface swap is atomic
and the old sinks remain private until their workers quiesce. A commit lease
prevents stale mutation; it does not by itself make C-context destruction or
shared-sink reconfiguration safe.

## 4. Seek and EOF state machine

### Session state

```text
closed
  -> opening -> probing -> ready
  -> prerolling -> playing <-> paused
  -> buffering -> prerolling
  -> seeking -> ready/playing/paused/ended
  -> recovering -> prerolling
  -> draining -> ended
any live state -> stopping -> closed
any live state -> failing -> closed
```

State changes are events reduced on the session actor. Product events derive
from committed state; timers do not invent lifecycle facts.

### Seek transaction

1. Accept/coalesce intent with priority: stop/replace > exact > keyframe >
   preview.
2. Snapshot desired paused/rate and authoritative clock time.
3. Advance `OperationGeneration` before side effects.
4. Cancel/interrupt active demux read and revoke old presentation commits.
5. Stop the timebase; serialize Apple flush completion; clear app queues.
6. Flush demux/parser, active codecs, audio resampler, subtitle decoder/converter,
   libass event/duplicate state, and renderer drain latches.
7. Map requested player time to media time and issue FFmpeg seek.
8. Decode from a keyframe/preroll point.
9. Exact: discard video before eligible target and trim leading PCM precisely.
   Keyframe: accept the returned boundary. Preview: video-only and paused.
10. Rebuild subtitle cues spanning the target from a sufficient earlier window.
11. Enqueue a declared preroll window or satisfy it with terminal EOF for short
    streams.
12. Commit the new lease/rate and publish a typed seek result containing actual
    landing times and completion reason.

### EOF transaction

Each required track advances:

```text
reading -> demuxEOF -> decoderDraining -> decodedEOF
        -> converterDraining -> samplesSubmitted
        -> presenterDraining -> presentedEOF
```

Global EOF requires every active required track to be `presentedEOF` or
explicitly disabled, no queued higher-priority operation, and a matching
generation. Subtitle final state is evaluated/cleared consistently. Seeking,
new packet arrival, track revision, or output recreation invalidates relevant
EOF latches.

Playlist advancement, completion marking, loop, and keep-open are product
policies after global EOF—not substitutes for it.

## 5. Error-recovery model

Use the taxonomy in [ERROR_RECOVERY.md](ERROR_RECOVERY.md). The essential rules:

- isolated corrupt input is skipped/counted;
- temporary starvation waits under cancellation;
- initial VT failure falls back to software;
- runtime VT gets one dependency/session recreation, then one software rebuild;
- format change reconfigures the affected pipeline atomically;
- audio/video renderer/device failure gets one flush/reprime and one recreation;
- subtitle failure disables only subtitles;
- optional track failure degrades explicitly;
- no playable A/V or internal lifetime violation terminates the session;
- retry counters reset only on named successful progress;
- a worker cannot call global seek/flush directly;
- a terminal fault revokes presentation and begins teardown immediately.

## 6. Capability model

Capabilities are values with reasons, not booleans derived from method names.

```text
CapabilityStatus
  supported
  supportedWithFallback(reason)
  temporarilyUnavailable(reason)
  unsupportedBySource(reason)
  unsupportedByDevice(reason)
  unsupportedByProduct(reason)
  failed(reason, retryAvailable)
```

Scopes:

- application: local file, supported command set;
- source: seekable, known duration, chapters, attachments;
- track: decoder/text/bitmap/format support;
- decoder: VT available/configured/active/software/recovering, requested policy,
  and whether a policy change is active now or deferred until the next load;
- presenter/display: pixel format, HDR/EDR, rotation/interlace;
- audio device: channels, sample rate, time-pitch/device selection;
- composition: subtitle types, PiP/screenshot inclusion.

Use tri-state track selection: `automatic`, `disabled`, `stream(stableID)`.
Reject malformed/out-of-range IDs without unchecked narrowing.

## 7. Diagnostics model

Add an in-memory bounded structured `EventJournal` with optional persisted test
artifact. Events include:

- state transitions with reason and identity tuple;
- open/probe budgets and source IO cancellation;
- stream/track discovery and selection score/reason;
- original and normalized PTS/DTS/duration decisions;
- queue count/bytes/time and backpressure duration;
- decoder name, requested/configured/actual hardware format, format revisions;
- corrupt/error counters and recovery decisions;
- decoded, dropped, enqueued, and renderer-reported counts separately;
- first decoded, first enqueued, first visible/readiness timestamps;
- seek requested/low-level/landed/completed times;
- synchronizer time/rate, starvation, auto-flush, renderer/device changes;
- each EOF/drain phase and final presentation interval;
- subtitle cue/revision/font/fallback/region metrics;
- teardown outstanding workers/callbacks/leases and deadline result.

Correct current mislabeling:

- do not call enqueue “first frame presented”;
- do not call last-submitted start-PTS delta A/V sync or buffered duration;
- do not report zero dropped frames from an unwired counter;
- preserve typed `isHardware`/fallback state through the product layer;
- do not call an empty software queue buffering while Apple holds healthy data;
- do not report shutdown complete after a timeout without a failed result.

## 8. Testing strategy

Three layers are mandatory:

1. deterministic reducer/queue/timeline/fault/race tests;
2. generated real-codec differential tests against the pinned mpv oracle and
   FFprobe truth dumps;
3. physical Mac/display/audio qualification.

The complete fixture, metric, tolerance, provenance, and CI plan is in
[TEST_FIXTURE_PLAN.md](TEST_FIXTURE_PLAN.md).

Current completion evidence includes 119 tests in 20 suites, production-driver
tests for delayed/duplicate/stale/failed/cancelled outcomes, architecture
validation, fresh ASan and TSan 12-reopen stress, three 60-second A/V soaks with
zero dropped frames, package/signature verification, and live packaged-app
smoke. This closes the authority-migration gate. It does **not** claim that the
pinned mpv runner/comparator, every fixture in the required matrix, or the full
physical device/display matrix is complete; those are the next testing phase.

Production architecture must expose test seams for:

- blocking/cancelling AVIO;
- controlled demux/decoder results;
- presenter commit barriers;
- Apple notification/failure adapters;
- monotonic test clock;
- deterministic memory/resource counters.

No test-only branch may change normal state semantics.

## 9. Features to implement

### Core acceptance scope

- cancellable local open/probe/read;
- explicit timeline including non-zero/negative/unknown duration;
- stable track catalog and automatic/disabled/stream selection;
- count/byte/time queues and priority control;
- correct send/receive/drain and resampler tail;
- exact/keyframe/preview seek with actual result and audio trim;
- renderer-drained EOF;
- global presentation epoch and waitable teardown;
- typed demux/decode/presentation/output/subtitle recovery;
- dynamic video/audio format revisions;
- actual hardware path/capability diagnostics;
- FFmpeg text subtitle conversion;
- libass reset/preroll/font lifetime; correct subtitle delay;
- metadata/SAR/range/color correctness;
- deterministic differential and physical qualification gates.

### After core acceptance

- PGS and VobSub bitmap region composition; DVB as evidence warrants;
- native multichannel decoded PCM;
- playback speed/time pitch if product-prioritized;
- audio delay/device selection;
- screenshot pipeline if product-prioritized;
- HTTP(S) source module only with cancellation/cache/security design.

## 10. Features to omit

For the planned architecture, omit:

- libmpv/OpenGL runtime and fallback;
- DVD/Blu-ray/optical-disc navigation;
- Lua scripting/load hooks;
- arbitrary shaders and broad filter graphs;
- platform-neutral AO/VO architecture;
- Linux/Windows-specific behavior;
- mpv CLI compatibility;
- reverse playback;
- audio passthrough;
- obscure protocols outside an allowlisted source module;
- frame interpolation and Dolby Vision FEL;
- secondary subtitles in the first architecture;
- Direct Metal/libplacebo until its evidence gate passes.

Rationale and revisit triggers are in
[ARCHITECTURE_OPTIONS.md](ARCHITECTURE_OPTIONS.md).

## 11. Ordered refactor sequence and acceptance criteria

### Completion reconciliation (2026-07-20)

The implementation combined several proposed milestones and used aggregate
native transactions, so completion must be judged by authority outcomes rather
than a one-to-one class or effect inventory.

| Outcome | Current status | Evidence or remaining boundary |
| --- | --- | --- |
| Pure deterministic core, identities, invariants, model/replay support | Complete | `SuperplayrPlaybackCore`; deterministic core tests and architecture validation |
| Serialized production command/result seam and reactive projection | Complete | `PlaybackRuntimeDriver`, `PlaybackViewStore`, static backend-bypass rejection |
| Native fences, leases, cancellation, seek, drain/EOF, recovery, synchronization, track/subtitle authority | Complete | Current production runtime plus the completion matrix; hostile identified-outcome tests cover the driver seam |
| Obsolete native orchestration and legacy libmpv/OpenGL removal | Complete | Native-only package at `e144086`, requalified after the `6825c6b` authority switch |
| Automated/sanitizer/soak/package/live-smoke authority gate | Complete | [NATIVE_PLAYBACK_QUALIFICATION.md](../NATIVE_PLAYBACK_QUALIFICATION.md) |
| Pinned mpv/FFprobe oracle and comparison artifacts | Remaining next phase | No completed `OracleRunner`/`Comparator` artifact is claimed |
| Full edge-fixture and physical device/display release matrix | Remaining evidence | Keep explicit fixture/device gaps open in [TEST_FIXTURE_PLAN.md](TEST_FIXTURE_PLAN.md) |

The milestone text below remains the original requirements decomposition. A
remaining fixture or physical proof item is not evidence that playback policy
still has two authorities.

### Milestone 0 — Freeze evidence and harness contract

Deliver:

- preserve this source analysis and exact pins;
- define structured events/result schema;
- make existing fixture absence a reported skip/failure according to CI mode;
- add a fixture manifest/checksum/license scheme;
- make the VFR generator fail unless `ffprobe` proves non-uniform PTS deltas;
- add test adapters without changing production behavior.

Acceptance:

- repository build/architecture checks pass;
- no external source checkout is tracked;
- every fixture and oracle binary is reproducible/hashed;
- current behavior baseline is captured before refactor.

### Milestone 1 — Async command bridge, session actor, and presentation epoch

Deliver:

- `NativePlaybackSession` reducer;
- asynchronous load command/result bridge from the current synchronous
  `PlayerBackend` API;
- playback epoch/operation generation/track revision types;
- serialized presentation/subtitle commit lease;
- terminal stop/failure path;
- product event adapter;
- replacement transaction: revoke, stop/cancel, join or isolate sinks, then
  configure/start the new epoch.

Acceptance:

- deterministic barriers prove old video, audio, subtitle, rate, recovery, error,
  and EOF cannot mutate after seek/replacement;
- repeated close of non-blocked sessions reaches zero workers/callbacks/leases;
- no behavior relies on a timer to establish lifecycle state.

The unconditional close-during-blocked-open/read gate follows in Milestone 2,
once the FFmpeg interrupt path exists.

### Milestone 2 — Async source, timeline, and queues

Deliver:

- cancellable off-main FFmpeg opener/reader with interrupt callback;
- staged probe/partial metadata;
- `TimelineMapper`;
- stable/dynamic track catalog;
- count/byte/time queues and control priority.

Acceptance:

- close/replace interrupts blocked open/read;
- positive and negative starts map correctly through playback, chapters, resume,
  seek, and EOF;
- unknown duration remains unknown and capability behavior is correct;
- queue budget tests cannot deadlock control.

### Milestone 3 — Seek, preroll, drain, and EOF

Deliver:

- explicit exact/keyframe/preview modes;
- complete flush transaction;
- exact FFmpeg send/receive/flush/drain contracts required by EOF;
- swresample tail drain and timestamp accounting;
- video eligibility and sample-accurate audio trim;
- per-stage EOF and presentation drain;
- typed seek result.

Acceptance:

- VFR/non-zero/negative/missing-duration/damaged seek matrix passes;
- rapid near-EOF seeks never hang or suppress conclusive EOF;
- seek after EOF follows the chosen keep-open or reload contract end to end;
- backward seek resets/generation-tags submit horizons before buffering is
  evaluated;
- final delayed video/audio/resampler samples play before product EOF;
- audio-only/video-only/short-stream preroll and EOF resolve.

### Milestone 4 — Decoder and format revision recovery

Deliver:

- actual VT configured/active status;
- typed corruption versus VT failure;
- one VT recreation then generation-safe software fallback;
- explicit hardware-policy semantics: either a typed active-decoder revision or
  a truthful next-load-only result; do not equate `compatibility` with
  `automatic` silently;
- dynamic video and audio format revisions;
- explicit software color conversion.

Acceptance:

- H.264/HEVC/VP9/AV1 8/10-bit matrix has documented path/outcome;
- injected initial/runtime VT failures meet budgets and land correctly;
- hardware policy commands report and produce the documented active/deferred
  outcome;
- corrupt packets do not spuriously force software until policy threshold;
- resolution/pixel/audio-format changes reconfigure without stale output;
- no stale pixel buffer is newly committed or presented after its lease is
  revoked, and buffers already retained by Apple are released by the defined
  flush/teardown quiescence point.

### Milestone 5 — Audio/output/device model

Deliver:

- sample-exact audio timeline and resampler rebuild on format/device revision;
- explicit preroll/starvation/buffering states;
- audio renderer error/auto-flush/device observers;
- bounded renderer/device recreation and video-only degradation;
- one session-owned pause/resume and sleep/wake recovery transaction;
- active-renderer-only readiness for audio-only and video-only sessions;
- accurate submission versus presentation diagnostics.

Acceptance:

- steady sync thresholds pass long CFR/VFR runs;
- device-switch fault tests pass;
- physical built-in/HDMI/USB/wireless and pause/resume pass;
- sleep/wake resumes only after the wake seek and active-renderer preroll commit;
- audio-only/video-only readiness, sufficient-media, and EOF do not wait on an
  inactive renderer;
- paused player releases power/CPU appropriately;
- stereo downmix fixtures prove contribution/no clipping.

### Milestone 6 — Subtitle architecture

Deliver:

- FFmpeg text subtitle conversion;
- atomic embedded/external selection and tri-state off;
- generation-safe libass reset/cue preroll;
- correct positive delay;
- per-file font budgets/lifetime and logging;
- bitmap subtitle capability reporting, then PGS/VobSub compositor.

Acceptance:

- embedded/external SRT/ASS plus external SSA/WebVTT intake, font,
  animated/karaoke, delay, seek, track switch, and
  external-survives-audio-switch cases pass;
- stale/duplicate cue barrier tests pass;
- unsupported bitmap tracks are never silently selected;
- when compositor ships, PGS/VobSub region/seek/forced tests pass.

### Milestone 7 — Picture correctness and physical qualification

Deliver:

- complete range/matrix/primaries/transfer/chroma/SAR/aperture/rotation/interlace
  propagation;
- explicit HDR/EDR and subtitle reference-white policy;
- objective and physical comparison artifacts;
- Metal decision record.

Acceptance:

- SDR 601/709/2020 limited/full, chroma, anamorphic, rotation, PQ, HLG,
  HDR→SDR fixtures pass documented thresholds;
- internal/external SDR/EDR/HDR display matrix passes;
- software fallback does not silently destroy required precision/color;
- Direct Metal is either rejected with evidence or separately approved under the
  [PICTURE_QUALITY.md](PICTURE_QUALITY.md) gate.

### Milestone 8 — Remove legacy mpv/OpenGL

Deliver:

- delete legacy engine/view/adapter and CMpv sources;
- remove OpenGL and mpv package/build/runtime closure;
- remove backend selection/default/fallback settings and tests;
- rename historical POC source/targets to production-native names;
- update architecture/build/package documentation.

Acceptance:

- dependency scan shows no libmpv/OpenGL runtime linkage;
- app always constructs the native backend;
- complete native automated and release physical matrices pass;
- packaging/signing/notarization and app-size/runtime dependency checks pass;
- no product command silently assumes mpv property/command semantics.

### Milestone 9 — Optional feature increments

Only after Milestone 8: multichannel PCM, rate/time pitch, audio delay/device UI,
screenshots, HTTP(S), secondary subtitles, or a separately approved Metal
presenter. Each receives its own capability, tests, and product value case.

## 12. Major risks

| Risk | Why it matters | Mitigation |
| --- | --- | --- |
| Apple renderer drain observability is limited | exact EOF/first-visible proof may not have one direct API | wrap all available status/notifications/timebase evidence; conservative final interval; physical tests; document unobservable facts |
| Actor/Dispatch/C callback crossing | reentrancy and non-Sendable C state can create new races | confine each C owner; callback shims emit immutable records; deterministic barriers/TSan |
| AVIO cancellation safety | callbacks can outlive Swift owner if context order is wrong | C-owned cancellation token with explicit lifetime; destroy after FFmpeg close/join |
| VT behavior varies by Mac/OS/resources | hardware path and errors are not deterministic | capability/fallback model, exact hardware matrix, software path acceptance |
| Timestamp normalization breaks resume/chapters | existing state assumes zero origin | central mapper; original+normalized journal; migration/regression tests |
| EOF remains under-specified by Apple | playlist may advance early/late | staged EOF and final interval evidence; never use queue EOS alone |
| Dynamic format change can retain old surfaces | wrong geometry/color or crashes | track revision, flush barrier, lease-based format configuration |
| Subtitle HDR/PiP composition diverges | separate AppKit overlay is not unified media output | explicit capability/reference-white policy; later unified compositor if gate fails |
| System dependency drift | runtime behavior may differ from analyzed source | record configurations/hashes; pin release artifacts/build recipes |
| Refactor scope expands | temptation to add mpv features during core work | milestone freeze and intentional-omission list |
| Async backend API migration leaks into product state | the current synchronous throwing `load` path cannot represent cancellable open | introduce an operation identity/event bridge first; keep playlist/UI state behind the existing neutral coordinator |
| Legacy removal happens too early/late | early removes comparison/safety; late preserves complexity | remove only after native acceptance, in a dedicated mechanical milestone |
| Licensing mistakes | FFmpeg configuration or copied source can alter obligations | no code copying; source/function/commit provenance; build-config audit and legal review |

## 13. Licensing and provenance notes

- This plan derives behavior, invariants, and tests from pinned sources; it does
  not copy their implementation.
- Most inspected mpv core files carry LGPL-2.1-or-later headers, but the default
  mpv program is GPL-2.0-or-later. An LGPL build requires excluding every
  GPL-only file; `-Dgpl=false` is only a build convenience, linked-library terms
  still matter, and embedded-origin functions have their own notices. mpv will
  not be retained in the planned runtime.
- FFmpeg core is generally LGPL-2.1-or-later, but enabled GPL/nonfree components
  and external libraries determine the distributed artifact's obligations.
  Record build flags and `avcodec_configuration()`.
- libass is ISC; retain notices and exact version/build provenance.
- libplacebo is LGPL-2.1-or-later and remains reference-only unless a separately
  approved renderer project adopts it.
- Apple frameworks are proprietary, OS/device-dependent platform APIs.
- The current Superplayr checkout has no top-level license file. Resolve that
  before any external-source adaptation analysis.
- Any future direct adaptation must be isolated, cite project/file/function/SHA,
  state the exact file license, preserve notices, and receive separate technical
  and legal review.

See [SOURCE_PINS.md](SOURCE_PINS.md) for full pins and file-level caveats.

## Final architecture move

The stateful native player core and native-only dependency closure described
here are implemented, and libmpv/OpenGL is removed. The next move is to validate
the completed authority path against the pinned mpv/FFprobe oracle and the
remaining physical Mac matrix, without reopening the dependency strategy or
claiming unrun fixture/device work complete.
