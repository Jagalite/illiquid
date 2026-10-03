# Architecture options

Status update (2026-07-20): Option 2 was implemented through `6825c6b`. The
native runtime is the sole production engine, the functional core is the
playback behavior authority, and the legacy libmpv/OpenGL path has been removed.
The option analysis below remains the 2026-07-19 decision record for baseline
`fbdc699`; unresolved oracle, fixture, and physical qualification work does not
mean the authority migration is incomplete.

## Decision

Baseline decision: choose **refactor the native architecture before adding more
features**.

Retain FFmpeg + VideoToolbox + Apple sample-buffer presentation + libass. Replace
only the narrow custom pieces whose dependency already has a better contract:
non-ASS text subtitle conversion should move to FFmpeg, and bitmap subtitle
decode should use FFmpeg when its compositor milestone arrives. The target
runtime has no legacy libmpv/OpenGL backend.

## Option 1: Continue current native architecture with targeted gap work

### Attractive parts

- smallest near-term diff;
- preserves working common-fixture decode;
- can add visible features quickly.

### Why it is rejected

The main gaps cross existing object boundaries:

- generations are session-local while presentation/subtitle sinks are shared;
- sink validation is not atomic with enqueue/rate/libass mutation;
- open is main-actor synchronous and cannot be cancelled;
- seek and EOF are distributed across queues, locks, timer polling, and backend
  events;
- failures are strings, not state transitions;
- track changes reconstruct the entire session and have no prepare/commit
  rollback;
- dynamic format and output-device revisions have no transaction.

Adding checks inside individual loops cannot close those races. A correct fix
requires new ownership and state boundaries. Therefore incremental feature work
would harden the wrong seams.

Evidence: `Superplayr:Media/MediaSession.swift`; `Production/
NativeAppleBackend.swift`; `Subtitles/SubtitlePipeline.swift @
fbdc699627bebf4298a630004ca31a31b0ec5df4`.

## Option 2: Refactor the native player core, retain dependencies

### Shape

- one session actor/reducer owns lifecycle and transitions;
- cancellable media opener;
- serialized FFmpeg demux actor;
- timeline mapper;
- per-track decode pipelines;
- epoch-checked Apple presentation session;
- separate subtitle decode/render/composition pipeline;
- typed recovery supervisor, capabilities, and event journal.

### Benefits

- directly addresses every high-risk source defect;
- preserves known-good FFmpeg/VT/libass ownership and near-zero-copy path;
- uses Apple's shared timebase instead of creating a duplicate sync loop;
- makes races and failures deterministic to test;
- removes legacy backend concepts without tying product APIs to one dependency;
- keeps Direct Metal optional and isolated.

### Costs

- meaningful internal reorganization before new features;
- must temporarily bridge current product events to richer native states;
- requires fault injection and test-only presenter adapters;
- physical qualification remains necessary.

### Decision

**Chosen and implemented.** The refactor remained bounded to the playback core,
native adapters, and reactive projection rather than rewriting product
playlist, persistence, or window policy. The implemented design uses a pure
core plus a serialized production driver and permits contractually explicit
aggregate native acknowledgements; the proposed “one session actor” shape was
an ownership model, not a required class layout.

## Option 3: Replace a subsystem with another Apple/dependency component

### Replace FFmpeg demux/decode with AVPlayer/AVAssetReader

Rejected. It would narrow format/codec/container behavior, complicate the
existing direct libass and track model, and does not remove the need for a
player-owned lifecycle/seek/error state machine. It also gives less control over
damaged-media and differential behavior.

### Replace Apple sample-buffer presentation with AVPlayer

Rejected. AVPlayer is an integrated media player, not a drop-in sink for this
FFmpeg-decoded architecture. Adapting the architecture around it would abandon
the chosen broad-format pipeline.

### Replace custom text subtitle parsing with FFmpeg

Accepted as part of Option 2. FFmpeg already decodes SRT/WebVTT/mov_text and
other text formats into ASS-compatible events. Superplayr should own timeline
and track policy, not parsing quirks.

Sources: `FFmpeg:libavcodec/srtdec.c::srt_to_ass,srt_decode_frame` and
`libavcodec/ass.c @ 162c2784f90969ae53c1f4aa36d22ef93945a293`
(LGPL-2.1-or-later).

### Replace bitmap subtitle decode with FFmpeg

Accepted when the compositor milestone begins. FFmpeg owns PGS/VobSub/DVB
decoder state. Superplayr must still compose timed regions.

### Replace libass with Apple text APIs

Rejected. AppKit/CoreText alone do not provide ASS compatibility, karaoke,
animation, collision handling, shaping semantics, or embedded font behavior.
libass is the correct specialized dependency.

### Replace swresample with AVAudioConverter

Not justified now. Either can convert PCM; the missing behavior is revision,
timestamp, drain, channel, and recovery policy. Keep swresample to minimize
change, then compare an Apple converter only if device/channel integration gives
a concrete benefit.

## Option 4: Build a Direct Metal presenter now

### Potential gains

- explicit range/color/tone/gamut behavior;
- controllable scaling/chroma/deinterlace/dither/deband;
- unified HDR subtitle/bitmap composition;
- color-consistent screenshots;
- transparent metrics and render scheduling.

### Why it is deferred

- it does not fix async open, generation races, exact audio seek, EOF drain,
  track state, or recovery;
- current metadata/software-path correctness is not established, so a new
  renderer could merely encode the same wrong inputs more explicitly;
- Apple's direct route has not failed a pinned physical acceptance matrix;
- Metal/libplacebo adds GPU/resource, PiP, power, packaging, and LGPL review;
- sample-buffer presentation is already the least risky macOS integration.

Direct Metal is a later presenter implementation behind the same core if the
decision gate in [PICTURE_QUALITY.md](PICTURE_QUALITY.md) is met.

## Option 5: Reconsider native playback because too much is missing

Rejected. The missing pieces are finite and architecturally identifiable:
player state, timeline, queue policy, presentation drain, recovery, subtitle
routing, diagnostics, and validation. FFmpeg, VideoToolbox, Apple renderers, and
libass already supply the difficult codec/container/hardware/text primitives.

mpv's source reinforces that a mature player is coordination around those
primitives. It does not demonstrate that Superplayr must embed mpv or reproduce
its output stack.

## Legacy libmpv/OpenGL disposition

At the `fbdc699` baseline, the repository still contained `CMpv`, the
`SuperplayrPlayer` legacy engine and OpenGL files, backend
selection/preferences/settings, tests, build scripts, and package linker
entries. Those were baseline facts, not target architecture.

They were removed in the native-only migration at `e144086`; the qualification
record at `6825c6b` confirms package resolution, strict bundle validation,
signature verification, and live packaged-app smoke. The completed disposition
is:

- no runtime fallback;
- no hidden `legacyMpv` default;
- no CMpv system-library target;
- no OpenGL linker setting;
- no dual-backend UI/settings/factory paths;
- retain only neutral product/session interfaces that still make sense.

The broader device/display release matrix remains a continuing product release
gate, not a reason to restore the removed runtime or treat backend authority as
unsettled.

## Evaluated intentional omissions

| Feature | Decision | Rationale | Revisit trigger |
| --- | --- | --- | --- |
| DVD/Blu-ray navigation | Omit | requires optical/menu/navigation stacks, not ordinary file playback | explicit disc-library product requirement |
| Optical-disc playback | Omit | hardware/DRM/navigation scope outside local media files | same |
| Lua scripting/load hooks | Omit | large security/compatibility surface; no product case | demonstrated automation/user ecosystem demand |
| Arbitrary user shaders | Omit | requires custom GPU presenter and support burden | Metal ships and target users demand it |
| Broad user video-filter graph | Omit | not required for core playback | named high-value filters |
| Obscure streaming protocols | Omit initially | security/cancellation/cache complexity; product is local-first | explicit source module with threat model |
| HTTP(S) playback | Defer, not permanently omit | common but requires AVIO cancellation/cache/auth policy | local core passes and product prioritizes URLs |
| Audio passthrough | Omit | device negotiation breaks volume/rate/simple sync; narrow audience | explicit home-theater requirement and device matrix |
| Extensive CLI compatibility | Omit | Superplayr is a GUI product, not mpv-compatible CLI | none planned |
| Platform-neutral VO/AO abstraction | Omit | macOS-only by premise | platform strategy changes |
| Linux/Windows behavior | Omit | outside product scope | product scope changes |
| Reverse playback | Omit | major cache/decode complexity, low product value | explicit editing/review use case |
| Secondary subtitles | Defer | useful niche feature but not core correctness | primary subtitle architecture stable and user demand |
| Direct Metal/libplacebo | Defer | needs evidence gate and licensing/build review | Apple path fails acceptance |
| Debanding/dither controls | Defer | enhancement, not current correctness | fixture/user evidence |
| Screenshots | Defer | requires color/subtitle-consistent capture path | product prioritizes capture |
| Native multichannel PCM | Implement later | meaningful Mac/HDMI value, unlike passthrough | core audio revision/device model complete |
| PGS/VobSub bitmap subtitles | Implement after core | common in anime/remux libraries | subtitle compositor milestone |
| DVB/teletext/ARIB breadth | Capability-gated/defer | less common for local target, parser/composition already possible via FFmpeg | target library evidence |
| Frame interpolation | Omit | high complexity and changes content motion | separate product feature case |
| Dolby Vision FEL | Omit | complex proprietary/decoder/display requirements | explicit supported-format initiative |

## Decision summary

The native coordination core and legacy removal are complete. The right next
move is the pinned differential harness and its self-verifying fixture/physical
evidence, followed by evidence-based feature decisions. A renderer rewrite
remains behind the existing picture-quality decision gate.
