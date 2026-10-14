# Illiquid: hierarchical agent ownership and continuous-improvement plan

**Version 2 — 40 component areas, 120 bounded audit topics, and a 44-role staffing model**

Prepared October 13, 2026. Repository: `Jagalite/illiquid`.
Pinned source revision: `d829a227caaa8bf1be4d42070655c494d669c4b7`.

## Executive recommendation

Yes: section Illiquid into **eight domains, 40 component areas, and smaller task-level audit topics**. An agent can be assigned a whole domain, one component, or one narrowly defined investigation. The hierarchy describes responsibility and context; a separate, exact job lease controls writes and execution resources.

Use **44 logical roles as the full-size planning model: 40 component workers, one scheduler/coordinator, one integration steward, and two independent verification stewards**. The eight domains do not require eight additional full-time managers. Those responsibilities can be held by a component worker or activated only for a cross-component change.

Forty components is a practical decomposition of the inspected code, not a measured optimal agent count, an equal-effort partition, or a claim that forty simultaneous production patches are independent. Keep the original four concurrent production-change slots during bootstrap. Expand to eight only after the baseline, ownership, and verification queues behave well. Additional agents can independently investigate, reproduce, design tests, run admitted experiments, or review existing patches. Increase again only from measured throughput, resource headroom, and merge/rework evidence.

The important distinction is **many independent questions, fewer simultaneous mutations of shared state, and an even smaller number of shared-hardware experiments**. A job should stop or move to a different question when it lacks a write or runner lease; it should not invent changes to remain busy.

This document expands the previous eight-domain plan. It changes the staffing and granularity proposal, not the authority, persistence, or playback architecture. Source directories have not been moved. No agents were spawned, repository configuration changed, or application tests run for this deliverable.

## 1. What was checked, and what remains a proposal

The map uses the package manifest, architecture documentation, actual source inventories, selected coordination code, native test inventory, qualification scripts, and the open PR. `main` was rechecked at the pinned SHA. The deterministic core already has distinct seek, load/drain, recovery, synchronization, track-selection, and subtitle helper files; native code has corresponding input, queue, decoder, runtime, presentation, and subtitle boundaries. [R01][R02][R03][R06]

The source anchors below are real observed paths or explicitly marked directories. They are **navigation and ownership seed data, not an exhaustive permission map**. A leaf's tests list identifies existing starting points, not blanket ownership of the listed test target. No claim is made that every file's body or every test has been audited. Before automated writes, resolve the seed against a fresh tracked-file inventory, assign each writable path once, and reject unmapped or ambiguously assigned paths. Module marker files, miscellaneous diagnostics, some resources, and shared historical tests deliberately require that preflight rather than a guessed owner.

At preparation, PR #1 remained open at head `a753599e74c3636724763638d1782079927d9091`, based on the pinned main SHA. It covers track restoration, thumbnail visibility/fairness, and migration/upgrade tooling. Its description reports prior test results and explicitly retains real-app and historical-upgrade qualification gaps. Those are not newly rerun results. Reserve that work and resolve its base before assigning overlapping fixes. A path described as PR-only must not be assumed to exist on main. [R12]

The names and responsibilities of new audit documents, task IDs, leases, manifests, and staffing profiles are proposals. A filename in a proposed artifact tree is not evidence of an existing implementation.

## 2. Assignment hierarchy and semantics

| Level | Example | Meaning | Appropriate assignment |
|---|---|---|---|
| Repository | `R` | Shared contracts, operating rules, dependency graph, overall acceptance | Coordinate a campaign or conduct a read-only system review |
| Domain | `A04` | A coherent subsystem containing several components | Own all subtitle work with a small team, or delegate its four leaves |
| Component | `A04.02` | Stable topic and code ownership, with neighboring contracts | Audit, reproduce, fix, and verify bitmap subtitles end to end |
| Audit topic | `A04.02.q3` | A bounded question inside a component, not a new permanent module | Investigate bitmap reconstruction after backward seeks |
| Job | `JOB-2026-0042` | A concrete hypothesis, base SHA, files, resources, budget, and evidence | One experiment or one reviewable patch |

An agent assigned a parent inherits its context and acceptance obligations. It does **not** gain unrestricted write permission over every descendant. With no delegation, it can request exact leases for any child. Once a child is delegated, the parent's mutable scope excludes that child; the parent coordinates and reads it. Reclaiming work requires the child's lease to be released or explicitly revoked and the job state preserved.

Concurrent mutable assignments must be non-overlapping after delegation. Do not run `fix A04` with an unrestricted subtree grant at the same time as `fix A04.02`. Read-only audits may overlap freely. Two independent reviewers may examine the same topic deliberately, but only the named patch owner receives the mutation lease.

The 120 `.q1/.q2/.q3` topics are starter questions, not 120 claims of code independence. They may be replaced by better evidence-driven questions without reorganizing the ownership tree. Multiple investigations inside one file can be useful; their fixes must still be serialized or explicitly handed to that file's owner.

### Coupling labels

**L — Local-file candidate.** There are distinct helper/component files that can often be changed independently under stable interfaces. It is not a claim of low risk, standalone compilation, or complete test isolation.

**C — Coupled integration area.** Normal behavior crosses one or more central state/coordination files. Investigation and new isolated tests can proceed in parallel; a fix may require a shared-file or contract lease.

**G — Governed contract or artifact.** Changes to authority, identity, persisted schemas, dependency inputs, package graph, or release behavior need explicit compatibility review. These areas can be investigated in parallel, but a file-local diff can still be a cross-system change.

These labels indicate likely coordination cost at the inspected revision. Every job is classified again based on its actual proposed diff. The label is not authorization.

## 3. Complete component tree

The original eight domain IDs are retained. The unequal leaf counts reflect different amounts and kinds of machinery; they are not a requirement to keep exactly forty areas forever.

```text
R  Illiquid
  A01  Playback authority and product coordination (6 components)
    A01.01  Authority contracts, identity, reducer, and invariants [G]
    A01.02  Load, drain, EOF, and completion policy [C]
    A01.03  Seek, transport, and supersession policy [L]
    A01.04  Synchronization, buffering, recovery, and wake policy [L]
    A01.05  Track and subtitle selection intent [C]
    A01.06  Product coordination, queue commitment, and view publication [C]
  A02  Native execution, decoding, and resource lifetime (7 components)
    A02.01  Demux, input execution, and read cancellation [L]
    A02.02  Packet queues, frame permits, and backpressure [L]
    A02.03  Video decode, conversion, and deinterlacing [C]
    A02.04  Audio decode, resampling, channel layout, and delay [L]
    A02.05  Native seeking, preroll, and frame stepping [L]
    A02.06  Media-session workers, candidates, and retirement [C]
    A02.07  Native operation ledger, effect dispatch, recovery, and shutdown [C]
  A03  Presentation, output, displays, and PiP (5 components)
    A03.01  Presentation clock, membership, demand, and observation [C]
    A03.02  Video surfaces, geometry, color sampling, and screenshots [L]
    A03.03  Audio presentation, devices, and route changes [L]
    A03.04  PiP controller lifecycle and window restoration [C]
    A03.05  PiP caption composition, GPU resources, and shader integration [C]
  A04  Subtitles and caption correctness (4 components)
    A04.01  Text subtitles, font attachments, and libass [L]
    A04.02  Bitmap subtitle decoding, composition, and reconstruction [L]
    A04.03  Subtitle source preparation, timing, revisions, and pipeline lifetime [C]
    A04.04  Main caption overlay, geometry, redraw, and memory budget [L]
  A05  Library, persistence, identity, and restoration (5 components)
    A05.01  Durable playback storage and coalesced writes [G]
    A05.02  Saved preferences, track records, and restore targets [G]
    A05.03  File identity, source preparation, and missing-source recovery [G]
    A05.04  Folder discovery, playlist data, source roots, and monitoring [L]
    A05.05  Metadata hints and legacy-state migration [G]
  A06  Thumbnails, previews, caches, and background budgets (4 components)
    A06.01  Thumbnail generation and request lifecycle [C]
    A06.02  Thumbnail memory/disk cache and invalidation [L]
    A06.03  Thumbnail metadata, blocking reads, and packet windows [L]
    A06.04  Background eligibility, fairness, power, and thumbnail settings [C]
  A07  App shell, interaction, accessibility, and lifecycle (5 components)
    A07.01  Application/window lifetime, startup, and platform events [C]
    A07.02  Transport controls, scrubbing, chrome, and OSD [C]
    A07.03  Commands, shortcuts, focus, accessibility, and Now Playing [L]
    A07.04  Source browser, navigation, tabs, and recovery UI [C]
    A07.05  Settings, themes, legibility, and motion [L]
  A08  Build, dependencies, packaging, updates, and CI (4 components)
    A08.01  Swift build graph, developer tooling, and test CI [G]
    A08.02  Native SDK, FFI packaging inputs, and dependency provenance [G]
    A08.03  App bundle, resources, distribution, and installation integrity [G]
    A08.04  Updater, release workflow, and historical-upgrade qualification [G]
  Cross-cutting roles (not additional production-code domains)
    C00  Scope, scheduling, budgets, and conflict coordination
    I00  Integration candidate, boundary review, and merge evidence
    V01  Deterministic behavior, model assumptions, and regression quality
    V02  Native output, system qualification, and performance evidence
```

## 4. Cross-cutting roles without creating a management bottleneck

**C00 — Coordinator.** Select bounded questions, pin the baseline, reserve existing work, issue exact leases, manage budgets, and resolve conflicts. The coordinator owns assignment state, not every implementation. It may suspend an unproductive or blocked experiment and reassign a worker without discarding its evidence.

**I00 — Integration steward.** Assemble an explicit integration candidate, check interface changes with affected owners, schedule affected-consumer tests, and record the candidate actually verified. It does not hand-fix every conflict or silently reinterpret a domain patch. Return semantic conflicts to their authors. This role may prepare a reviewed merge candidate, but it does not gain release/signing permission.

**V01 — Behavior and model verification steward.** Own the assumptions and quality of state-space/replay oracles, shared deterministic harness semantics, retained counterexamples, and cross-domain behavioral scenarios. Source work centers on `IlliquidPlaybackStateSpace`, its tests, the state-space explorer, and related harnesses, resolved to exact paths. Model and invariant changes receive author-independent review. The production reducer remains A01.01-owned. [R01][R02]

**V02 — Native/output/performance verification steward.** Own shared real-media/system campaigns, differential/output oracles, benchmark method, artifact integrity, and physical-device/release qualification boundaries. Source work centers on relevant `Validation/`, `Benchmarks/`, and shared native test infrastructure, not blanket authority to change production code. A08.01 owns script/CI wiring; V01/V02 review changes to what those scripts claim to verify. [R09][R11][R16]

These two verifiers should not manually execute and approve every low-risk patch. Pair component workers for independent review of ordinary local changes; use automated retained gates; reserve verification stewards for oracle changes, new campaigns, high-risk seams, and sampled audits. A worker reviewing another worker's patch is not an extra full-time role. The implementer must not approve its own evidence or silently update the test oracle.

Security, concurrency, memory/performance, accessibility, and compatibility are **cross-cutting review lenses**, not five additional teams with competing ownership of every file. Route their findings to the affected leaf. Parser, native FFI, filesystem, workflow, and release changes warrant explicit security attention. A cross-cutting reviewer can receive a temporary exact patch lease, but not a repository-wide write exemption.

## 5. Component charters

Every component has the same end-to-end responsibility: inspect relevant callers and callees, select a bounded question, reproduce or measure, create an appropriate regression, propose or implement the smallest justified fix, and supply verification evidence. Tests and diagnostics are part of the component's work. A clean audit with a useful coverage boundary is a valid deliverable.

**How to read a charter:** anchors identify the starting code; audit topics are assignable investigations; test entry points are candidates to inspect and resolve; shared seam IDs name coordination points in section 6; neighbor IDs are potential reviewers when their contracts are affected, not a requirement for every listed neighbor to approve every line edit. Proposed fixes remain subject to exact write leases and the shared contract.

## A01 — Playback authority and product coordination

Core contracts and accepted product state; no native framework execution.

### A01.01 — Authority contracts, identity, reducer, and invariants

**Coordination class: G. Parent: A01.**

Own the authoritative event/effect vocabulary, session and generation identity, central reduction, and invariant definitions. Review other core leaves without becoming the author of all their tests.

**Observed source anchors**

- `Sources/IlliquidPlaybackCore/IdentityAndTime.swift`
- `Sources/IlliquidPlaybackCore/EventsAndEffects.swift`
- `Sources/IlliquidPlaybackCore/PlaybackCore.swift`
- `Sources/IlliquidPlaybackCore/PlaybackCoreState.swift`
- `Sources/IlliquidPlaybackCore/PlaybackInvariants.swift`
- `Sources/IlliquidPlaybackCore/PlaybackModelRuntime.swift`
- `Sources/IlliquidPlaybackCore/PlaybackReplay.swift`
- `Sources/IlliquidPlayback/PlaybackRuntime.swift`
- `Sources/IlliquidPlayback/PlaybackRuntimeEvent.swift`
- `Sources/IlliquidPlayback/PlaybackCapabilities.swift`
- `Sources/IlliquidPlayback/PlaybackSurfaceHost.swift`
- `Sources/IlliquidPlayer/Player/ArchitectureValidation.swift`

**Assignable audit topics**

- **A01.01.q1 — Identity reuse:** Can duplicate, stale, or mismatched outcomes change accepted state?
- **A01.01.q2 — Reducer boundaries:** Do all commands and results pass the intended authority gates?
- **A01.01.q3 — Invariant quality:** Can replay and deliberately invalid transitions distinguish missing checks from correct rejection?

**Verification starting points:** `Tests/IlliquidPlaybackCoreTests/`; `Tests/IlliquidPlaybackTests/`; `Validation/IlliquidArchitectureCheck/`.

**Acceptance:** No duplicate authority or unreviewed contract change; retain minimal failing traces and bounded exploration assumptions. Native output remains separately qualified.

**Shared seams:** S01. **Review when affected:** A01.02, A01.03, A01.04, A01.05, A01.06, A02.07, V01.

Source basis: [R01] [R02] [R03].

### A01.02 — Load, drain, EOF, and completion policy

**Coordination class: C. Parent: A01.**

Own logical load readiness, end-of-stream/drain decisions, and permission to complete or advance. Product queue mutation remains in A01.06.

**Observed source anchors**

- `Sources/IlliquidPlaybackCore/LoadingAndDrainCore.swift`

**Assignable audit topics**

- **A01.02.q1 — Drain ordering:** Can one stream ending early cause premature completion?
- **A01.02.q2 — Checkpoint failure:** Can failed persistence or an intervening command still allow advancement?
- **A01.02.q3 — Replacement at EOF:** What happens when EOF races a new source, repeat, seek, or shutdown?

**Verification starting points:** `Tests/IlliquidPlaybackCoreTests/`; `Tests/IlliquidPlayerTests/`.

**Acceptance:** Advancement has one accepted cause and observes the checkpoint contract; audio-only, video-only, and zero-output outcomes are explicit.

**Shared seams:** S01, S02. **Review when affected:** A01.06, A02.06, A03.01, A05.01.

Source basis: [R02] [R03].

### A01.03 — Seek, transport, and supersession policy

**Coordination class: L. Parent: A01.**

Own logical seek barriers and accepted transport intent, not native decoder seeking or pointer presentation.

**Observed source anchors**

- `Sources/IlliquidPlaybackCore/SeekCore.swift`
- `Sources/IlliquidCore/Utilities/PlaybackTimeInput.swift`

**Assignable audit topics**

- **A01.03.q1 — Latest intent:** Does the newest accepted seek win under reordered completion?
- **A01.03.q2 — Pause and rate:** Can a late result resume playback against the latest pause/rate intent?
- **A01.03.q3 — Targets and boundaries:** How are invalid times, start/end boundaries, repeated targets, and interrupted scrubbing handled?

**Verification starting points:** `Tests/IlliquidPlaybackCoreTests/`; `Tests/IlliquidCoreTests/`.

**Acceptance:** Preserve requested intent through all tested schedules; demonstrate native responsiveness separately from logical correctness.

**Shared seams:** S01, S02. **Review when affected:** A01.01, A01.06, A02.05, A07.02.

Source basis: [R02] [R03].

### A01.04 — Synchronization, buffering, recovery, and wake policy

**Coordination class: L. Parent: A01.**

Own deterministic decisions for buffering, drift response, recovery escalation, and authorized wake recovery.

**Observed source anchors**

- `Sources/IlliquidPlaybackCore/SynchronizationCore.swift`
- `Sources/IlliquidPlaybackCore/RecoveryCore.swift`

**Assignable audit topics**

- **A01.04.q1 — Recovery budget:** Can repeated failures spin, reset a spent budget, or escalate the wrong stream?
- **A01.04.q2 — Buffering progress:** Are starvation, progress, drain, and stable pause distinguished?
- **A01.04.q3 — Wake authority:** Can old wake/recovery acknowledgements affect a replacement session?

**Verification starting points:** `Tests/IlliquidPlaybackCoreTests/`.

**Acceptance:** Recovery is bounded and identity-scoped; no second wall-clock or synchronization policy is introduced in the native layer.

**Shared seams:** S01. **Review when affected:** A02.07, A03.01, A03.03, A07.01.

Source basis: [R02] [R03].

### A01.05 — Track and subtitle selection intent

**Coordination class: C. Parent: A01.**

Own desired track/source semantics and matching policy, including explicit Off versus automatic selection. The persisted record belongs to A05.02.

**Observed source anchors**

- `Sources/IlliquidPlaybackCore/TrackSelectionCore.swift`
- `Sources/IlliquidPlaybackCore/SubtitleCore.swift`
- `Sources/IlliquidCore/Player/MediaTrack.swift`
- `Sources/IlliquidCore/Player/TrackSelectionPreferences.swift`
- `Sources/IlliquidCore/Player/SubtitleFallbackEncoding.swift`

**Assignable audit topics**

- **A01.05.q1 — Intent precedence:** When do explicit choices override automatic and saved choices?
- **A01.05.q2 — Ambiguous metadata:** Are identical metadata, reused IDs, and changed stream order handled according to the stated guarantee?
- **A01.05.q3 — Replacement intent:** Do selections and delay intent survive successful replacement and rollback without leaking to a different source?

**Verification starting points:** `Tests/IlliquidPlaybackCoreTests/`; `Tests/IlliquidCoreTests/`; `Tests/IlliquidPlayerTests/`.

**Acceptance:** Distinguish unchanged-file ID tie-breaking from stable content identity; verify the accepted selection and observed track content independently.

**Shared seams:** S01, S02, S10. **Review when affected:** A01.06, A04.03, A05.02, A02.06.

Source basis: [R02] [R03] [R04] [R12].

### A01.06 — Product coordination, queue commitment, and view publication

**Coordination class: C. Parent: A01.**

Own product command routing, committed source/playlist state, checkpoint initiation, runtime lifetime at the product boundary, and immutable view publication.

**Observed source anchors**

- `Sources/IlliquidPlayer/Player/PlaybackController.swift`
- `Sources/IlliquidPlayer/Player/PlaybackRuntimeDriver.swift`
- `Sources/IlliquidPlayer/Player/PlaybackCheckpointWriter.swift`
- `Sources/IlliquidPlayer/Player/PlaybackVideoColorStore.swift`
- `Sources/IlliquidPlayer/Player/PlayerCapabilityModel.swift`
- `Sources/IlliquidPlayer/Player/PlaybackBenchmarkControl.swift`
- `Sources/IlliquidCore/Player/PlaybackCommand.swift`
- `Sources/IlliquidCore/Player/PlaybackModels.swift`
- `Sources/IlliquidCore/Player/PlaybackPhase.swift`
- `Sources/IlliquidCore/Player/PlaybackRecoveryIssue.swift`
- `Sources/IlliquidCore/Player/PlaybackState.swift`
- `Sources/IlliquidCore/Player/PlaybackViewStore.swift`
- `Sources/IlliquidCore/Player/MediaSource.swift`

**Assignable audit topics**

- **A01.06.q1 — Candidate publication:** Can a failed candidate publish or persist state as though it were committed?
- **A01.06.q2 — Open and queue ordering:** Are Finder opens, explicit enqueues, restore, and rapid replacements ordered consistently?
- **A01.06.q3 — Projection freshness:** Can delayed callbacks or passive saves overwrite newer state or undo a user clear?

**Verification starting points:** `Tests/IlliquidPlayerTests/`; `Tests/IlliquidPlaybackTests/`.

**Acceptance:** Product metadata, queue position, playback authority, and persistence agree after success, rollback, and shutdown; no decoder policy moves into the coordinator.

**Shared seams:** S02, S01, S03, S04, S10. **Review when affected:** A01.02, A02.07, A05.01, A05.02, A05.04, A06.01, A07.01.

Source basis: [R02] [R04] [R05].

## A02 — Native execution, decoding, and resource lifetime

Physical media work and resource ownership; no independent playback policy.

### A02.01 — Demux, input execution, and read cancellation

**Coordination class: L. Parent: A02.**

Own input opening, packet extraction, native read execution, error classification, and input cancellation; shared FFI surface changes require A08.02 review.

**Observed source anchors**

- `Sources/IlliquidNativePlayback/Media/FFmpegDemuxer.swift`
- `Sources/IlliquidNativePlayback/Media/FFmpegInputExecutor.swift`
- `Sources/IlliquidNativePlayback/Media/FFmpegError.swift`
- `Sources/IlliquidNativePlayback/Media/FFmpegPacket.swift`
- `Sources/IlliquidNativePlayback/Media/FFmpegStreamInfo.swift`

**Assignable audit topics**

- **A02.01.q1 — Bad input:** Do truncated, corrupt, or unexpected streams fail without unbounded retries?
- **A02.01.q2 — Blocked I/O:** Are logical cancellation and still-running operating-system reads accounted for separately?
- **A02.01.q3 — Open/close churn:** Can repeated cancelled or failed opens leak handles, workers, or packet ownership?

**Verification starting points:** `Tests/IlliquidNativePlaybackTests/InputReadFailureTests.swift`; `Tests/IlliquidNativePlaybackTests/NativePlaybackFoundationTests.swift`.

**Acceptance:** Bound physical occupancy even when cancellation cannot stop an OS operation; do not claim hard I/O deadlines from a waiter timeout.

**Shared seams:** S03, S04, S12. **Review when affected:** A02.02, A02.06, A02.07, A05.03, A08.02.

Source basis: [R02] [R06].

### A02.02 — Packet queues, frame permits, and backpressure

**Coordination class: L. Parent: A02.**

Own queue admission, capacity accounting, cancellation-aware waits, and read/decode backpressure. Global budget policy is a shared contract.

**Observed source anchors**

- `Sources/IlliquidNativePlayback/Playback/FixedRingBuffer.swift`
- `Sources/IlliquidNativePlayback/Playback/PacketQueue.swift`
- `Sources/IlliquidNativePlayback/Media/MediaReadAheadGate.swift`
- `Sources/IlliquidNativePlayback/Runtime/RendererDemandGate.swift`
- `Sources/IlliquidNativePlayback/Runtime/VideoFrameCapacityGate.swift`

**Assignable audit topics**

- **A02.02.q1 — Accounting:** Are permits and queued bytes released exactly once on every exit?
- **A02.02.q2 — Blocked producer/consumer:** Can flush, cancellation, pause, or shutdown leave an unrecoverable waiter?
- **A02.02.q3 — Starvation and bounds:** Do small budgets remain correct, and do sustained producers remain bounded?

**Verification starting points:** `Tests/IlliquidNativePlaybackTests/NativePlaybackFoundationTests.swift`; `Tests/IlliquidNativePlaybackTests/NativePlaybackFixtureIntegrationTests.swift`.

**Acceptance:** Exercise capacities at boundaries and under cancellation; prove accounting assertions without removing valid demand or worsening output under the acceptance workload.

**Shared seams:** S03, S04, S05. **Review when affected:** A02.03, A02.04, A02.06, A03.01.

Source basis: [R02] [R06] [R07].

### A02.03 — Video decode, conversion, and deinterlacing

**Coordination class: C. Parent: A02.**

Own hardware/software decode mechanics, pixel conversion, format attachments, and deinterlacing execution. Core recovery authorization remains elsewhere.

**Observed source anchors**

- `Sources/IlliquidNativePlayback/Media/VideoDecoder.swift`
- `Sources/IlliquidNativePlayback/Media/VideoDeinterlacer.swift`

**Assignable audit topics**

- **A02.03.q1 — Decode/fallback:** Are delayed frames, hardware failure, and software continuation fenced correctly?
- **A02.03.q2 — Format and color:** Are geometry, range, matrix, chroma position, and bit depth preserved across supported paths?
- **A02.03.q3 — Interlaced drain:** Are field cadence, EOF drain, seek flush, and format changes correct?

**Verification starting points:** `Tests/IlliquidNativePlaybackTests/HardwareVideoOutputTests.swift`; `Tests/IlliquidNativePlaybackTests/PlanarPrecisionReferenceTests.swift`; `Tests/IlliquidNativePlaybackTests/SoftwareVideoColorConversionTests.swift`.

**Acceptance:** Use independent pixel/code-value and timeline references plus real-media runs; retain unsupported-format fallbacks and bounded pool behavior.

**Shared seams:** S03, S04, S05. **Review when affected:** A02.02, A02.05, A02.06, A03.02, A08.02.

Source basis: [R02] [R06] [R09].

### A02.04 — Audio decode, resampling, channel layout, and delay

**Coordination class: L. Parent: A02.**

Own decoded PCM, resampler draining, channel mapping, signed-delay timeline mapping, and decode-side audio capacity.

**Observed source anchors**

- `Sources/IlliquidNativePlayback/Media/AudioDecoder.swift`
- `Sources/IlliquidNativePlayback/Media/AudioDelayTimeline.swift`
- `Sources/IlliquidNativePlayback/Media/NativeAudioOutputCapacity.swift`

**Assignable audit topics**

- **A02.04.q1 — Resampler boundaries:** Are delayed samples, EOF, short packets, and changed formats drained correctly?
- **A02.04.q2 — Channel identity:** Does each speaker receive the expected samples across supported layouts and fallback?
- **A02.04.q3 — Delay and trim:** Do signed offsets and exact seeks preserve sample order through track replacement?

**Verification starting points:** `Tests/IlliquidNativePlaybackTests/AudioDelayTests.swift`; `Tests/IlliquidNativePlaybackTests/AudioResamplerDrainTests.swift`; `Tests/IlliquidNativePlaybackTests/MultichannelAudioTests.swift`.

**Acceptance:** Retain sample-level or analytical references; separate PCM correctness from actual device output and perceptual A/V synchronization.

**Shared seams:** S03, S05. **Review when affected:** A02.05, A02.06, A03.03, A01.05.

Source basis: [R02] [R06] [R09].

### A02.05 — Native seeking, preroll, and frame stepping

**Coordination class: L. Parent: A02.**

Own execution of accepted seeks, exact trim/preroll mechanics, and frame-step reads, not logical selection of the winning command.

**Observed source anchors**

- `Sources/IlliquidNativePlayback/Playback/PlaybackGeneration.swift`
- `Sources/IlliquidNativePlayback/Playback/SeekCoordinator.swift`
- `Sources/IlliquidNativePlayback/Playback/SeekPerformanceTimings.swift`
- `Sources/IlliquidNativePlayback/Playback/SeekPrerollDecodePolicy.swift`
- `Sources/IlliquidNativePlayback/Playback/SoftwareSeekAccelerationPolicy.swift`
- `Sources/IlliquidNativePlayback/Media/NativeFrameStepReader.swift`
- `Sources/IlliquidNativePlayback/Media/MediaTime.swift`

**Assignable audit topics**

- **A02.05.q1 — Flush barriers:** Can an old packet, sample, or frame escape after the seek fence?
- **A02.05.q2 — Target precision:** Do VFR, nonzero origins, long GOPs, and audio trimming meet the target contract?
- **A02.05.q3 — Rapid scrubbing:** Are superseded requests cheap to abandon and final seeks still completed?

**Verification starting points:** `Tests/IlliquidNativePlaybackTests/SeekPrerollDecodeTests.swift`; `Tests/IlliquidNativePlaybackTests/SoftwareSeekAccelerationTests.swift`; `Tests/IlliquidNativePlaybackTests/SeekPerformanceQualificationTests.swift`.

**Acceptance:** Report accepted intent, actual output timestamps, and latency distributions separately; performance runs must be isolated from other heavy jobs.

**Shared seams:** S03, S04, S05. **Review when affected:** A01.03, A02.03, A02.04, A03.01, A04.03.

Source basis: [R02] [R06] [R09].

### A02.06 — Media-session workers, candidates, and retirement

**Coordination class: C. Parent: A02.**

Own the physical session graph, worker lifetime, selected-stream execution, and candidate preparation/retirement; runtime-level commit authority is A02.07.

**Observed source anchors**

- `Sources/IlliquidNativePlayback/Media/MediaSession.swift`
- `Sources/IlliquidNativePlayback/Media/NativeTrackSelection.swift`

**Assignable audit topics**

- **A02.06.q1 — Candidate isolation:** Can a preparing candidate publish frames or subtitles before commit?
- **A02.06.q2 — Rollback resource set:** Are old, active, candidate, and retiring workers accounted for on every failure?
- **A02.06.q3 — Worker teardown:** Do repeated replacement, shutdown, and missing callbacks stabilize resource usage?

**Verification starting points:** `Tests/IlliquidNativePlaybackTests/NativePlaybackFixtureIntegrationTests.swift`; `Tests/IlliquidNativePlaybackTests/NativeTrackSelectionTests.swift`; `Validation/IlliquidPlaybackStress/`.

**Acceptance:** No physical session loses ownership before cleanup; exercise commit failure and rollback as well as successful opens.

**Shared seams:** S03, S04, S05, S06. **Review when affected:** A02.01, A02.02, A02.03, A02.04, A02.07, A04.03.

Source basis: [R02] [R06] [R09].

### A02.07 — Native operation ledger, effect dispatch, recovery, and shutdown

**Coordination class: C. Parent: A02.**

Own dispatch and correlation of accepted effects, native replacement commit/rollback, late-result rejection, and aggregate physical shutdown.

**Observed source anchors**

- `Sources/IlliquidNativePlayback/Production/NativePlaybackRuntime.swift`
- `Sources/IlliquidNativePlayback/Production/NativeOperationTransaction.swift`
- `Sources/IlliquidNativePlayback/Production/NativePausedReadbackDiagnostic.swift`
- `Sources/IlliquidNativePlayback/Runtime/NativeRecoveryController.swift`
- `Sources/IlliquidNativePlayback/Runtime/NativeSynchronizationController.swift`
- `Sources/IlliquidNativePlayback/Runtime/PlaybackRuntimeMetadata.swift`

**Assignable audit topics**

- **A02.07.q1 — Exact correlation:** Can one callback complete a different effect or a reused generation?
- **A02.07.q2 — Supersession/deadline:** Does a cancelled operation lose authority while its resource cleanup remains tracked?
- **A02.07.q3 — Shutdown fallback:** Does physical cleanup still occur after logical shutdown rejection or invariant failure?

**Verification starting points:** `Tests/IlliquidNativePlaybackTests/RuntimeAuthorityFenceTests.swift`; `Tests/IlliquidNativePlaybackTests/NativePlaybackFixtureIntegrationTests.swift`; `Validation/IlliquidPlaybackStress/`.

**Acceptance:** Maintain a distinction between logical completion and physical cleanup; retain failed-shutdown diagnostics rather than declaring success prematurely.

**Shared seams:** S04, S03, S01, S02, S05, S06. **Review when affected:** A01.01, A01.06, A02.06, A03.01, A04.03, V01.

Source basis: [R02] [R06] [R07].

## A03 — Presentation, output, displays, and PiP

Application of playback decisions to actual output and platform surfaces.

### A03.01 — Presentation clock, membership, demand, and observation

**Coordination class: C. Parent: A03.**

Own physical presentation graph membership, accepted clock/rate application, readiness, fences, and bounded observation.

**Observed source anchors**

- `Sources/IlliquidNativePlayback/Presentation/NativePresentationCoordinator.swift`

**Assignable audit topics**

- **A03.01.q1 — Membership:** Are audio/video, audio-only, video-only, and zero-output transitions safe?
- **A03.01.q2 — Observation cost:** Do paused or hidden states avoid redundant work without starving valid demand?
- **A03.01.q3 — Fence and preroll:** Can stale samples or clock observations restore the wrong rate?

**Verification starting points:** `Tests/IlliquidNativePlaybackTests/PresentationTimeObservationTests.swift`; `Tests/IlliquidNativePlaybackTests/RendererObservationBoundsTests.swift`.

**Acceptance:** Verify actual renderer progress separately from enqueue success; never stop valid PiP demand merely because the main view is hidden.

**Shared seams:** S05, S03, S04. **Review when affected:** A01.04, A02.02, A02.07, A03.02, A03.03, A03.04.

Source basis: [R02] [R07] [R09].

### A03.02 — Video surfaces, geometry, color sampling, and screenshots

**Coordination class: L. Parent: A03.**

Own video surface attachment and sample presentation, crop/rotation/aspect mapping, sampling, and screenshot output.

**Observed source anchors**

- `Sources/IlliquidNativePlayback/Presentation/SampleBufferVideoPresenter.swift`
- `Sources/IlliquidNativePlayback/Presentation/NativePlayerView.swift`
- `Sources/IlliquidNativePlayback/Presentation/NativeScreenshot.swift`
- `Sources/IlliquidNativePlayback/Presentation/VideoFrameColorSampler.swift`
- `Sources/IlliquidNativePlayback/Presentation/VideoViewport.swift`
- `Sources/IlliquidNativePlayback/Production/NativePlaybackSurfaceHost.swift`
- `Sources/IlliquidCore/Player/VideoColorSample.swift`
- `Sources/IlliquidCore/Player/VideoPresentationGeometry.swift`

**Assignable audit topics**

- **A03.02.q1 — Surface lifetime:** Can detach/reopen or resize reveal an obsolete surface or frame?
- **A03.02.q2 — Geometry:** Are crop, SAR, rotation, and display-size changes mapped consistently?
- **A03.02.q3 — Capture correctness:** Do screenshots and sampled colors represent the intended frame and color interpretation?

**Verification starting points:** `Tests/IlliquidNativePlaybackTests/NativePlaybackFixtureIntegrationTests.swift`; `Tests/IlliquidNativePlaybackTests/NativePlayerInputRoutingTests.swift`; `Tests/IlliquidCoreTests/`.

**Acceptance:** Use generated geometry/color references and an actual display path; readback evidence is not a physical HDR brightness qualification.

**Shared seams:** S05, S07. **Review when affected:** A02.03, A03.01, A03.05, A07.01.

Source basis: [R02] [R07].

### A03.03 — Audio presentation, devices, and route changes

**Coordination class: L. Parent: A03.**

Own output-device observation, speaker capability reporting, renderer application, and route-change execution.

**Observed source anchors**

- `Sources/IlliquidNativePlayback/Presentation/SampleBufferAudioPresenter.swift`
- `Sources/IlliquidNativePlayback/Presentation/NativeAudioDeviceMonitor.swift`
- `Sources/CNativeAudio/`

**Assignable audit topics**

- **A03.03.q1 — Route churn:** Are stale device callbacks ignored across disconnect, reconnect, and replacement?
- **A03.03.q2 — Output topology:** Do supported channel layouts and unavailable devices degrade explicitly?
- **A03.03.q3 — Recovery continuity:** Are accepted route-recovery operations applied without introducing a new clock owner?

**Verification starting points:** `Tests/IlliquidNativePlaybackTests/NativeAudioDeviceTests.swift`; `Tests/IlliquidNativePlaybackTests/AudioOutputNotificationTests.swift`; `Tests/IlliquidNativePlaybackTests/MultichannelAudioTests.swift`.

**Acceptance:** Confirm actual device behavior on suitable hardware; synthetic capability snapshots are narrower evidence.

**Shared seams:** S05, S04. **Review when affected:** A01.04, A02.04, A03.01, A07.01.

Source basis: [R02] [R07] [R09].

### A03.04 — PiP controller lifecycle and window restoration

**Coordination class: C. Parent: A03.**

Own native PiP transitions, desired-active intent, callback identity, and the platform restore handshake.

**Observed source anchors**

- `Sources/IlliquidNativePlayback/Presentation/NativePictureInPictureController.swift`
- `Sources/IlliquidNativePlayback/Presentation/PiPVideoMapping.swift`
- `Sources/IlliquidCore/Player/PictureInPictureState.swift`

**Assignable audit topics**

- **A03.04.q1 — Transition races:** Does start-while-stopping replay once, and do duplicate callbacks remain harmless?
- **A03.04.q2 — Missing callback:** Does bounded stop cleanup complete without claiming an unobserved restore?
- **A03.04.q3 — Window handshake:** Is restore success reported only after the intended surface is attached and visible?

**Verification starting points:** `Tests/IlliquidNativePlaybackTests/NativePictureInPictureTransitionTests.swift`; `Tests/IlliquidNativePlaybackTests/PiPVideoMappingTests.swift`.

**Acceptance:** Test actual app/window/PiP transitions as well as pure transition tests; stop timeout is not proof that AVKit delivered a callback.

**Shared seams:** S05, S07, S04. **Review when affected:** A03.01, A03.02, A03.05, A07.01.

Source basis: [R02] [R07] [R09].

### A03.05 — PiP caption composition, GPU resources, and shader integration

**Coordination class: C. Parent: A03.**

Own composited PiP output, video-only fallback, output pools and GPU lifetime. This leaf is the shared shader-file steward; subtitle kernels require A04.04 review.

**Observed source anchors**

- `Sources/IlliquidNativePlayback/Presentation/PiPSubtitleCompositor.swift`
- `Sources/IlliquidNativePlayback/Presentation/PiPSubtitleCompositionPolicy.swift`
- `Sources/IlliquidNativePlayback/Presentation/NativeMetalShaderLibrary.swift`
- `Sources/IlliquidNativePlayback/Resources/NativePlaybackShaders.metal`

**Assignable audit topics**

- **A03.05.q1 — Color preservation:** Do supported SDR/P010/PQ/HLG paths preserve the specified code-value behavior?
- **A03.05.q2 — Pool pressure:** Does exhausted staging/pool capacity remain bounded without stale captions or invalid frames?
- **A03.05.q3 — Failure fallback:** Can compositor failure degrade to video-only PiP without changing main-window playback?

**Verification starting points:** `Tests/IlliquidNativePlaybackTests/PiPSubtitleCompositionPolicyTests.swift`; `Tests/IlliquidNativePlaybackTests/PiPSubtitlePipelineTests.swift`; `Tests/IlliquidNativePlaybackTests/PlanarPrecisionReferenceTests.swift`.

**Acceptance:** Protect the direct main-video path; qualify pool pressure and frame identity, and keep physical HDR claims separate from offscreen tests.

**Shared seams:** S08, S06, S05. **Review when affected:** A02.03, A03.04, A04.03, A04.04, V02.

Source basis: [R02] [R07] [R08] [R09].

## A04 — Subtitles and caption correctness

Caption content, reconstruction, timing, and overlay correctness.

### A04.01 — Text subtitles, font attachments, and libass

**Coordination class: L. Parent: A04.**

Own text parsing/typesetting adaptation, attached font handling, and the libass boundary.

**Observed source anchors**

- `Sources/IlliquidNativePlayback/Subtitles/LibassContext.swift`
- `Sources/IlliquidNativePlayback/Subtitles/FontAttachmentStore.swift`
- `Sources/CLibass/`

**Assignable audit topics**

- **A04.01.q1 — Fonts and fallback:** Are embedded fonts, absent fonts, and unusual names handled consistently and within limits?
- **A04.01.q2 — Text/animation:** Are multiline, styled, animated, Unicode, and malformed captions interpreted safely?
- **A04.01.q3 — Parser ownership:** Are parser/cache allocations released or bounded across replacement and failed input?

**Verification starting points:** `Tests/IlliquidNativePlaybackTests/ExternalSubtitleEncodingTests.swift`; `Tests/IlliquidNativePlaybackTests/MetalASSSubtitleCompositorTests.swift`.

**Acceptance:** Use authored reference captions and explicit visual expectations; dependency changes require provenance and compatibility review.

**Shared seams:** S06, S08, S12. **Review when affected:** A04.03, A04.04, A08.02.

Source basis: [R02] [R08] [R09].

### A04.02 — Bitmap subtitle decoding, composition, and reconstruction

**Coordination class: L. Parent: A04.**

Own bitmap subtitle adaptation, crop/placement, display-set lifetime, and seek reconstruction mechanics.

**Observed source anchors**

- `Sources/IlliquidNativePlayback/Media/SubtitleDecoder.swift`
- `Sources/IlliquidNativePlayback/Subtitles/BitmapSubtitleTimeline.swift`
- `Sources/IlliquidNativePlayback/Subtitles/PGSSubtitlePresentation.swift`

**Assignable audit topics**

- **A04.02.q1 — Display lifetime:** Are PGS clear/replacement and DVD/DVB expiry semantics preserved?
- **A04.02.q2 — Crop and placement:** Can palette, alpha, crop, or destination geometry corrupt output?
- **A04.02.q3 — Seek reconstruction:** Does forward/backward seeking reconstruct an applicable display set rather than a stale one?

**Verification starting points:** `Tests/IlliquidNativePlaybackTests/BitmapSubtitleTests.swift`; `Tests/IlliquidNativePlaybackTests/PGSSubtitleCropTests.swift`; `Tests/IlliquidNativePlaybackTests/ExternalVobSubTests.swift`.

**Acceptance:** Preserve independent expected pixels/events for tiny fixtures; do not infer broad format qualification from a small generated corpus.

**Shared seams:** S06. **Review when affected:** A02.01, A04.03, A04.04.

Source basis: [R02] [R08] [R09].

### A04.03 — Subtitle source preparation, timing, revisions, and pipeline lifetime

**Coordination class: C. Parent: A04.**

Own prepared external inputs and caption pipeline execution, including Off/embedded/external modes, time mapping, revisions, and candidate isolation.

**Observed source anchors**

- `Sources/IlliquidNativePlayback/Subtitles/PreparedExternalSubtitle.swift`
- `Sources/IlliquidNativePlayback/Subtitles/SubtitlePipeline.swift`
- `Sources/IlliquidNativePlayback/Subtitles/SubtitleRevisionFence.swift`
- `Sources/IlliquidNativePlayback/Media/NativeSubtitleSource.swift`
- `Sources/IlliquidCore/Playlist/ExternalSubtitleMatcher.swift`

**Assignable audit topics**

- **A04.03.q1 — Source mode:** Can an audio change or replacement silently re-enable embedded captions while Off/external is selected?
- **A04.03.q2 — Delayed work:** Can stale reads, parses, or renders publish after a seek, delay change, or replacement?
- **A04.03.q3 — External pairs:** Are sidecar pairing, changed files, external catalogs, and preparation timeouts explicit?

**Verification starting points:** `Tests/IlliquidNativePlaybackTests/SubtitleSeekRegressionTests.swift`; `Tests/IlliquidNativePlaybackTests/ExternalVobSubTests.swift`; `Tests/IlliquidCoreTests/`.

**Acceptance:** Only the accepted source/revision may publish; main and PiP pipeline commitment and rollback remain consistent.

**Shared seams:** S06, S03, S04, S02. **Review when affected:** A01.05, A02.06, A02.07, A04.01, A04.02, A05.03.

Source basis: [R02] [R08] [R09].

### A04.04 — Main caption overlay, geometry, redraw, and memory budget

**Coordination class: L. Parent: A04.**

Own main-window caption composition, cached/paused redraw, overlay geometry, and subtitle memory accounting. The physical shared shader file is stewarded by A03.05.

**Observed source anchors**

- `Sources/IlliquidNativePlayback/Subtitles/MetalASSSubtitleCompositor.swift`
- `Sources/IlliquidNativePlayback/Subtitles/SubtitleOverlayView.swift`
- `Sources/IlliquidNativePlayback/Subtitles/SubtitleGeometry.swift`
- `Sources/IlliquidNativePlayback/Subtitles/SubtitleMemoryBudget.swift`

**Assignable audit topics**

- **A04.04.q1 — Redraw invalidation:** Do exposure, resize, delay, and pause redraw exactly the applicable caption?
- **A04.04.q2 — Overlay pixels:** Are text atlas and premultiplied bitmap alpha/geometry correct?
- **A04.04.q3 — Memory pressure:** Do active/candidate/main/PiP allocations stay within their stated budgets and degrade correctly?

**Verification starting points:** `Tests/IlliquidNativePlaybackTests/MetalASSSubtitleCompositorTests.swift`; `Tests/IlliquidNativePlaybackTests/PiPSubtitlePipelineTests.swift`.

**Acceptance:** Retain a separate normal-video path; validate budget accounting and actual visual output, not just allocation counters.

**Shared seams:** S06, S08. **Review when affected:** A03.02, A03.05, A04.01, A04.02, A04.03.

Source basis: [R02] [R08] [R09].

## A05 — Library, persistence, identity, and restoration

Durable state, source identity, discovery, and restoration data.

### A05.01 — Durable playback storage and coalesced writes

**Coordination class: G. Parent: A05.**

Own durable history/session data, write coalescing, failure reporting, and publication of saved state; the product checkpoint trigger is A01.06.

**Observed source anchors**

- `Sources/IlliquidCore/Persistence/PlaybackPersistenceStore.swift`
- `Sources/IlliquidCore/Persistence/PlaybackSessionStore.swift`
- `Sources/IlliquidCore/Persistence/CoalescingPersistenceWriter.swift`

**Assignable audit topics**

- **A05.01.q1 — Interrupted write:** Can partial writes or process interruption replace the last valid state?
- **A05.01.q2 — Coalescing order:** Can a delayed write overwrite a newer snapshot or a deliberate history clear?
- **A05.01.q3 — Unreadable state:** Are corruption, disk-full, permissions, and retry behavior explicit without silent data loss?

**Verification starting points:** `Tests/IlliquidCoreTests/`; `Tests/IlliquidPlayerTests/`.

**Acceptance:** Preserve defined durability and retry semantics; use disposable process-level crash tests where a process-kill guarantee is claimed.

**Shared seams:** S10, S02. **Review when affected:** A01.02, A01.06, A05.02, A05.05, V01.

Source basis: [R02] [R04] [R12].

### A05.02 — Saved preferences, track records, and restore targets

**Coordination class: G. Parent: A05.**

Own the persisted preference schema, default/per-file precedence, restore records, and backward-compatible interpretation.

**Observed source anchors**

- `Sources/IlliquidCore/Persistence/MediaPlaybackSettings.swift`
- `Sources/IlliquidCore/Persistence/PlaybackPreferences.swift`
- `Sources/IlliquidCore/Persistence/PlaybackRestoreTarget.swift`

**Assignable audit topics**

- **A05.02.q1 — Round trip:** Do settings and Off/explicit choices survive actual serialization and reopening?
- **A05.02.q2 — Override precedence:** Does a per-file choice remain distinguishable from a global default or reset?
- **A05.02.q3 — Older records:** Are missing optional fields and ambiguous legacy records handled without invented identity?

**Verification starting points:** `Tests/IlliquidCoreTests/`; `Tests/IlliquidPlayerTests/`.

**Acceptance:** Compatibility statements must name supported record versions; unchanged-file restoration does not prove restoration after ambiguous renumbering.

**Shared seams:** S10, S02, S01. **Review when affected:** A01.05, A01.06, A05.01, A05.05, A07.05.

Source basis: [R02] [R04] [R12].

### A05.03 — File identity, source preparation, and missing-source recovery

**Coordination class: G. Parent: A05.**

Own identity/version preparation, lexical-versus-canonical URL behavior, bounded filesystem execution, and moved/replaced source interpretation.

**Observed source anchors**

- `Sources/IlliquidCore/Persistence/MediaContentVersion.swift`
- `Sources/IlliquidCore/Utilities/NormalizedFileURL.swift`
- `Sources/IlliquidCore/Utilities/SourcePreparationExecutor.swift`
- `Sources/IlliquidCore/Utilities/MediaFileSupport.swift`
- `Sources/IlliquidNativePlayback/Media/NativeFileContentVersion.swift`

**Assignable audit topics**

- **A05.03.q1 — Identity versus path:** Can a different file at the same path inherit inappropriate state or cache content?
- **A05.03.q2 — Move/disconnect:** Can Locate, remount, symlinks, or inaccessible roots produce stale or misleading identities?
- **A05.03.q3 — Preparation pressure:** Do blocked workers and queued waiters obey the recorded admission and timeout contract?

**Verification starting points:** `Tests/IlliquidCoreTests/`; `Tests/IlliquidNativePlaybackTests/NativeFileContentVersionTests.swift`.

**Acceptance:** Preserve bounded physical worker occupancy and explicit identity strength; never call a normalized path stable content identity.

**Shared seams:** S10, S03, S07. **Review when affected:** A02.01, A04.03, A05.04, A06.02, A07.04.

Source basis: [R02] [R04] [R06].

### A05.04 — Folder discovery, playlist data, source roots, and monitoring

**Coordination class: L. Parent: A05.**

Own discovered source/playlist data and filesystem monitoring. Actual playback queue commitment is A01.06; browser navigation/rendering is A07.04.

**Observed source anchors**

- `Sources/IlliquidCore/Playlist/FolderPlaylist.swift`
- `Sources/IlliquidCore/Playlist/FolderPlaylistDiscovery.swift`
- `Sources/IlliquidCore/Playlist/PlaylistMutation.swift`
- `Sources/IlliquidCore/Utilities/NaturalFilenameOrdering.swift`
- `Sources/IlliquidApp/App/SourceRootIndex.swift`
- `Sources/IlliquidApp/App/SourceRootPruning.swift`
- `Sources/IlliquidApp/App/SourceStartupSnapshot.swift`
- `Sources/IlliquidApp/App/ReadOnlyStartupLoader.swift`
- `Sources/IlliquidApp/UI/SourceFilesystemMonitor.swift`
- `Sources/IlliquidApp/UI/SourceMediaPresenceScanner.swift`

**Assignable audit topics**

- **A05.04.q1 — Discovery cancellation:** Can a superseded scan publish into a newer request or closed tab?
- **A05.04.q2 — Ordering and mutation:** Do natural ordering, duplicates, removals, and playlist data changes retain the intended items?
- **A05.04.q3 — Root monitoring:** Are removed, inaccessible, reconnected, or large roots treated without deleting valid saved intent?

**Verification starting points:** `Tests/IlliquidCoreTests/`; `Tests/IlliquidAppTests/`.

**Acceptance:** Bound background scanning and retain destination identity; distinguish unavailable storage from an intentionally removed source.

**Shared seams:** S02, S07, S09. **Review when affected:** A01.06, A05.03, A06.04, A07.04.

Source basis: [R02] [R04] [R10].

### A05.05 — Metadata hints and legacy-state migration

**Coordination class: G. Parent: A05.**

Own metadata hint interpretation and the legacy migration adapter. These are two smaller adapter families grouped for staffing, not a claim that parsing and migration share implementation.

**Observed source anchors**

- `Sources/IlliquidCore/MediaLibrary/MediaMetadataHints.swift`
- `Sources/IlliquidCore/MediaLibrary/MediaNameRecognition.swift`
- `Sources/IlliquidCore/MediaLibrary/MediaSidecarReader.swift`
- `Sources/IlliquidCore/MediaLibrary/NFOMetadataHints.swift`
- `Sources/IlliquidCore/MediaLibrary/PlexMatchHints.swift`
- `Sources/IlliquidCore/Persistence/LegacyPreferencesMigration.swift`

**Assignable audit topics**

- **A05.05.q1 — Hint robustness:** Are malformed or conflicting sidecars bounded, and is hint precedence explicit?
- **A05.05.q2 — Migration interruption:** Can partial copy or post-publication/pre-marker interruption poison a retry?
- **A05.05.q3 — Downgrade/re-upgrade:** Are current-state precedence, retained source data, and one-time import semantics preserved?

**Verification starting points:** `Tests/IlliquidCoreTests/`; `Validation/ReleaseQualification/ (PR #1 path; not assumed present on main)`.

**Acceptance:** Keep parser and migration fixes in separate PRs; primitive migration success is not proof of installed historical-upgrade preservation.

**Shared seams:** S10, S11. **Review when affected:** A05.01, A05.02, A08.04, V01.

Source basis: [R04] [R12].

## A06 — Thumbnails, previews, caches, and background budgets

The preview pipeline across package boundaries, not unrelated playback decoding.

### A06.01 — Thumbnail generation and request lifecycle

**Coordination class: C. Parent: A06.**

Own preview intent execution, generation cancellation, completion identity, and worker/generator coordination.

**Observed source anchors**

- `Sources/IlliquidNativePlayback/Media/NativeTimelineThumbnailGenerator.swift`
- `Sources/IlliquidNativePlayback/Media/TimelineThumbnailWorker.swift`

**Assignable audit topics**

- **A06.01.q1 — Superseded preview:** Can old-source or old-hover work publish after a newer request?
- **A06.01.q2 — Cancellation and retry:** Is eligible current intent retained or deliberately abandoned according to a stated contract?
- **A06.01.q3 — Decode interference:** Does preview activity remain bounded without starving main playback?

**Verification starting points:** `Tests/IlliquidNativePlaybackTests/NativeThumbnailCacheTests.swift`; `Tests/IlliquidNativePlaybackTests/ThumbnailOptimizationQualificationTests.swift`.

**Acceptance:** Verify source-scoped result publication and useful response latency; avoid solving preview work by changing playback authority.

**Shared seams:** S09, S02. **Review when affected:** A02.03, A06.02, A06.03, A06.04, A07.02.

Source basis: [R05] [R06] [R09] [R12].

### A06.02 — Thumbnail memory/disk cache and invalidation

**Coordination class: L. Parent: A06.**

Own cache keys, bounded retention, disk publication, invalidation, and stale-content rejection.

**Observed source anchors**

- `Sources/IlliquidNativePlayback/Media/NativeThumbnailCache.swift`
- `Sources/IlliquidNativePlayback/Media/NativeThumbnailDiskCache.swift`

**Assignable audit topics**

- **A06.02.q1 — Identity changes:** Are replaced/moved files, changed dimensions, and differing sample requests keyed appropriately?
- **A06.02.q2 — Disk failure:** Can partial or corrupt cache entries be mistaken for valid images?
- **A06.02.q3 — Eviction:** Are memory/disk growth and cache-hit usefulness measured without unbounded retention?

**Verification starting points:** `Tests/IlliquidNativePlaybackTests/NativeThumbnailCacheTests.swift`; `Tests/IlliquidNativePlaybackTests/ThumbnailCacheQualificationTests.swift`.

**Acceptance:** Show correctness with warm and cold caches, disk failures, and changed sources; retain cache schema/version review.

**Shared seams:** S09, S10. **Review when affected:** A05.03, A06.01, A06.04.

Source basis: [R06] [R09].

### A06.03 — Thumbnail metadata, blocking reads, and packet windows

**Coordination class: L. Parent: A06.**

Own low-level thumbnail probing, bounded packet/sample windows, blocking-reader accounting, and decode observation.

**Observed source anchors**

- `Sources/IlliquidNativePlayback/Media/NativeThumbnailMetadataReader.swift`
- `Sources/IlliquidNativePlayback/Media/ThumbnailBlockingReader.swift`
- `Sources/IlliquidNativePlayback/Media/ThumbnailDecodeObservation.swift`
- `Sources/IlliquidNativePlayback/Media/ThumbnailPacketWindow.swift`

**Assignable audit topics**

- **A06.03.q1 — Slow metadata:** Does a slow probe starve later candidates or exceed physical occupancy bounds?
- **A06.03.q2 — Window bounds:** Can long GOPs, large packets, or unusual durations cause excessive read/decode work?
- **A06.03.q3 — Cancellation evidence:** Are timeout, cancelled wait, and genuinely ended native work distinguished?

**Verification starting points:** `Tests/IlliquidNativePlaybackTests/ThumbnailOptimizationQualificationTests.swift`; `Tests/IlliquidNativePlaybackTests/NativePlaybackFoundationTests.swift`.

**Acceptance:** Keep per-source resource use bounded; test slow probing and slow decoding separately rather than treating both as the same failure.

**Shared seams:** S09. **Review when affected:** A02.01, A02.03, A06.01, A06.04.

Source basis: [R06] [R09] [R12].

### A06.04 — Background eligibility, fairness, power, and thumbnail settings

**Coordination class: C. Parent: A06.**

Own background work eligibility, budget/fairness policy, and thumbnail-specific settings. Window truth is supplied by A07.01; it is not re-inferred here.

**Observed source anchors**

- `Sources/IlliquidCore/Player/ThumbnailPolicy.swift`
- `Sources/IlliquidApp/App/ThumbnailBackgroundScheduler.swift`
- `Sources/IlliquidApp/UI/ThumbnailSettingsCard.swift`

**Assignable audit topics**

- **A06.04.q1 — Visibility:** Are hide, minimize, occlusion, close, and restore reflected without changing playback/PiP authority?
- **A06.04.q2 — Fairness:** Do slow first candidates and repeated budget cancellation still allow later files to progress?
- **A06.04.q3 — Pressure and opt-in:** Are memory, thermal, power, and explicit background preferences obeyed?

**Verification starting points:** `Tests/IlliquidAppTests/`; `Tests/IlliquidCoreTests/`; `Tests/IlliquidNativePlaybackTests/ThumbnailOptimizationQualificationTests.swift`.

**Acceptance:** Test actual lifecycle wiring and cancellation-aware slow inputs; scheduling eligibility is not a measured battery-saving result.

**Shared seams:** S09, S07. **Review when affected:** A05.04, A06.01, A06.03, A07.01, A07.05.

Source basis: [R04] [R06] [R10] [R12].

## A07 — App shell, interaction, accessibility, and lifecycle

User and operating-system interaction without taking playback authority.

### A07.01 — Application/window lifetime, startup, and platform events

**Coordination class: C. Parent: A07.**

Own the composition root, app/window lifecycle, launch/open ordering at the shell, surface reattachment, and platform event delivery.

**Observed source anchors**

- `Sources/IlliquidApp/App/AppModel.swift`
- `Sources/IlliquidApp/App/AppDelegate.swift`
- `Sources/IlliquidApp/App/IlliquidApp.swift`
- `Sources/IlliquidApp/App/LaunchOpenQueue.swift`
- `Sources/IlliquidApp/App/PlaybackSystemCoordinator.swift`
- `Sources/IlliquidApp/App/WindowCloseBehavior.swift`
- `Sources/IlliquidApp/UI/PlayerRootView.swift`
- `Sources/IlliquidApp/UI/PlayerWindowControls.swift`
- `Sources/IlliquidApp/UI/VideoSurface.swift`
- `Sources/IlliquidApp/UI/WindowAccessor.swift`
- `Sources/IlliquidCore/Utilities/AspectFitWindowSizing.swift`
- `Sources/IlliquidCore/Utilities/LifecyclePerformance.swift`

**Assignable audit topics**

- **A07.01.q1 — Close and reopen:** Can closing a window destroy application-lived playback, persistence, or observers?
- **A07.01.q2 — Platform races:** Do hide, minimize, sleep/wake, PiP restore, and source-open events target the right lifetime?
- **A07.01.q3 — Startup authority:** Are Finder opens, restored session state, and window creation sequenced explicitly?

**Verification starting points:** `Tests/IlliquidAppTests/`; `Documentation/MANUAL_PLAYBACK_CHECKLIST.md`.

**Acceptance:** Exercise real process/window lifecycle in a disposable profile; do not infer real GUI success solely from synthetic notifications.

**Shared seams:** S07, S02, S05, S09. **Review when affected:** A01.06, A03.02, A03.04, A05.04, A06.04.

Source basis: [R02] [R10] [R12].

### A07.02 — Transport controls, scrubbing, chrome, and OSD

**Coordination class: C. Parent: A07.**

Own control interaction and presentation, scrubbing affordances, preview display, chrome reveal/hide, and OSD behavior.

**Observed source anchors**

- `Sources/IlliquidApp/App/PlaybackChromeController.swift`
- `Sources/IlliquidApp/App/PlaybackOSD.swift`
- `Sources/IlliquidApp/UI/ElasticPlaybackControlBar.swift`
- `Sources/IlliquidApp/UI/PlaybackControlBar.swift`
- `Sources/IlliquidApp/UI/PlaybackControlBarHost.swift`
- `Sources/IlliquidApp/UI/GoToTimeView.swift`
- `Sources/IlliquidApp/UI/PreviewDrawingProbe.swift`

**Assignable audit topics**

- **A07.02.q1 — Scrub interaction:** Does pointer/keyboard interaction preserve the intended final seek under buffering and source changes?
- **A07.02.q2 — Chrome timing:** Can hidden controls, pointer cooldowns, or focus changes lose commands?
- **A07.02.q3 — State projection:** Do visible progress, pending labels, and previews reflect accepted state without inventing playback truth?

**Verification starting points:** `Tests/IlliquidAppTests/`; `Documentation/KEYBOARD_AND_POINTER_CONTROLS.md`.

**Acceptance:** Verify both control-bar implementations where applicable; keep input behavior, accepted command, and observed playback results separate.

**Shared seams:** S07, S02, S09. **Review when affected:** A01.03, A01.06, A06.01, A07.03, A07.05.

Source basis: [R10] [R05].

### A07.03 — Commands, shortcuts, focus, accessibility, and Now Playing

**Coordination class: L. Parent: A07.**

Own semantic command routing, shortcut customization, focus/accessibility conventions, remote controls, and default-player interaction.

**Observed source anchors**

- `Sources/IlliquidApp/App/PlayerCommands.swift`
- `Sources/IlliquidApp/App/PlayerInteractionModel.swift`
- `Sources/IlliquidApp/App/PlayerShortcutBindings.swift`
- `Sources/IlliquidApp/App/PlayerUXPolicy.swift`
- `Sources/IlliquidApp/App/NowPlayingCoordinator.swift`
- `Sources/IlliquidApp/App/DefaultVideoPlayer.swift`
- `Sources/IlliquidApp/UI/ShortcutSettingsView.swift`

**Assignable audit topics**

- **A07.03.q1 — Command parity:** Do menu, keyboard, pointer, and remote commands map to the same accepted actions?
- **A07.03.q2 — Focus/accessibility:** Are text entry, sliders, VoiceOver, and system-reserved shortcuts respected?
- **A07.03.q3 — Now Playing lifecycle:** Are handlers and metadata fresh after replacement, window closure, and shutdown?

**Verification starting points:** `Tests/IlliquidAppTests/`; `Tests/IlliquidNativePlaybackTests/NativePlayerInputRoutingTests.swift`.

**Acceptance:** Accessibility is an audit lens across all UI leaves; this leaf coordinates it but does not gain unrestricted ownership of every view.

**Shared seams:** S07, S02. **Review when affected:** A01.06, A03.02, A07.01, A07.02, A07.04, A07.05.

Source basis: [R10] [R05].

### A07.04 — Source browser, navigation, tabs, and recovery UI

**Coordination class: C. Parent: A07.**

Own source-browser projection, navigation/tab intent, filtering, recovery affordances, and the shell tab store. Filesystem monitoring itself belongs to A05.04.

**Observed source anchors**

- `Sources/IlliquidApp/UI/SourcesSidebar.swift`
- `Sources/IlliquidApp/UI/SourceBrowserFilter.swift`
- `Sources/IlliquidApp/UI/SourceNavigationState.swift`
- `Sources/IlliquidApp/UI/SourceSidebarTabs.swift`
- `Sources/IlliquidApp/UI/SourceTreeProjectionInput.swift`
- `Sources/IlliquidApp/UI/OpenVideoTabBar.swift`
- `Sources/IlliquidApp/UI/PlaybackRecoveryView.swift`
- `Sources/IlliquidApp/App/OpenVideoTabStore.swift`
- `Sources/IlliquidCore/Player/OpenVideoTabs.swift`

**Assignable audit topics**

- **A07.04.q1 — Destination identity:** Can an async result land in the wrong tab or a removed source?
- **A07.04.q2 — Browser projection:** Are filtering, large trees, missing roots, selection, and accessibility consistent?
- **A07.04.q3 — Recovery explanation:** Does Locate/retry show the real failure and preserve position without pretending a different file is identical?

**Verification starting points:** `Tests/IlliquidAppTests/`; `Tests/IlliquidCoreTests/`.

**Acceptance:** Exercise source changes while scans/opens are pending; tab persistence schema changes need A05 review.

**Shared seams:** S07, S02, S10. **Review when affected:** A01.06, A05.03, A05.04, A07.03.

Source basis: [R10] [R04] [R05].

### A07.05 — Settings, themes, legibility, and motion

**Coordination class: L. Parent: A07.**

Own settings presentation, theme/material behavior, scale, contrast, and motion preferences. The underlying persisted schema remains A05.02.

**Observed source anchors**

- `Sources/IlliquidApp/UI/SettingsView.swift`
- `Sources/IlliquidApp/UI/TrackSelectionSettings.swift`
- `Sources/IlliquidApp/UI/PlayerTheme.swift`
- `Sources/IlliquidApp/UI/AdaptiveTextLegibility.swift`
- `Sources/IlliquidApp/UI/PlayerOverlayMaterial.swift`
- `Sources/IlliquidApp/UI/PlayerInterfaceScale.swift`
- `Sources/IlliquidApp/UI/IlliquidMotion.swift`

**Assignable audit topics**

- **A07.05.q1 — Settings semantics:** Can a UI update reset unrelated global or per-file preferences?
- **A07.05.q2 — Legibility:** Do controls remain usable across backgrounds, scale settings, and accessibility preferences?
- **A07.05.q3 — Motion and cost:** Do animations respect user intent and stop when their presentation is no longer needed?

**Verification starting points:** `Tests/IlliquidAppTests/`; `Documentation/MANUAL_PLAYBACK_CHECKLIST.md`.

**Acceptance:** No unsolicited redesign or behavior change disguised as cleanup; pair visual evidence with interaction and preference-persistence tests.

**Shared seams:** S07, S10. **Review when affected:** A05.02, A06.04, A07.02, A07.03.

Source basis: [R10] [R04].

## A08 — Build, dependencies, packaging, updates, and CI

Build/release integrity; no unauthorized production signing or publication.

### A08.01 — Swift build graph, developer tooling, and test CI

**Coordination class: G. Parent: A08.**

Own package/toolchain wiring and developer/CI entry-point integrity. V01/V02 own the semantic oracles and gates; changes to these shared scripts require their review.

**Observed source anchors**

- `Package.swift`
- `Package.resolved`
- `Documentation/BUILDING.md`
- `Scripts/run-native-qualification.sh`
- `Scripts/run-playback-state-space.sh`

**Assignable audit topics**

- **A08.01.q1 — Clean checkout:** Can a fresh supported host build and discover the intended tests using the recorded commands?
- **A08.01.q2 — Silent skips:** Do absent fixtures, empty filters, stale names, or early returns make a required lane misleadingly green?
- **A08.01.q3 — CI boundaries:** Are PR validation, untrusted code, caches, and release permissions separated?

**Verification starting points:** `Package.swift`; `Scripts/run-native-qualification.sh`; `Scripts/run-playback-state-space.sh`; `Tests/ (inventory/discovery; not blanket write permission)`.

**Acceptance:** Resolve exact commands against the checked-out revision; a passing wrapper must report the evidence actually executed, not merely exit zero.

**Shared seams:** S11, S12, S13. **Review when affected:** A01.01, A08.02, A08.04, V01, V02.

Source basis: [R01] [R09] [R11].

### A08.02 — Native SDK, FFI packaging inputs, and dependency provenance

**Coordination class: G. Parent: A08.**

Own reviewed dependency versions, SDK/header/library compatibility, provenance, inventories, and native lock changes. CFFmpeg is a shared boundary stewarded here; CLibass/CNativeAudio edits require the respective owners.

**Observed source anchors**

- `BuildInputs/`
- `DependencySources/`
- `Scripts/native-dependencies.lock.json`
- `Licenses/`
- `LICENSING.md`
- `THIRD_PARTY_NOTICES.md`
- `Sources/CFFmpeg/`

**Assignable audit topics**

- **A08.02.q1 — Compatibility:** Do headers, libraries, architectures, and compile settings describe the same inputs?
- **A08.02.q2 — Provenance:** Are archives and dependency inventories consistent with the packaged binaries?
- **A08.02.q3 — Untrusted media boundary:** Are dependency-related parser/resource risks escalated without an unreviewed library swap?

**Verification starting points:** `Scripts/ (resolved dependency verification tests)`; `BuildInputs/README.md`; `DependencySources/README.md`.

**Acceptance:** Never regenerate a lock just to hide a mismatch; version updates are explicit compatibility changes, and provenance does not itself prove reproducible binaries.

**Shared seams:** S12. **Review when affected:** A02.01, A02.03, A04.01, A03.03, A08.03.

Source basis: [R01] [R11].

### A08.03 — App bundle, resources, distribution, and installation integrity

**Coordination class: G. Parent: A08.**

Own bundle layout, embedded dependency closure, architecture/resource auditing, ad-hoc packaging, and installed-copy smoke checks.

**Observed source anchors**

- `Resources/`
- `DISTRIBUTING.md`
- `Documentation/CORRESPONDING_SOURCE.md`
- `Scripts/build-illiquid-app.sh`
- `Scripts/audit-illiquid-app.sh`
- `Scripts/package-illiquid-dmg.sh`

**Assignable audit topics**

- **A08.03.q1 — Dependency closure:** Can packaged runtime paths escape the bundle or omit a required library?
- **A08.03.q2 — Resource integrity:** Are shader/resources, metadata, architectures, and signatures checked on the actual artifact?
- **A08.03.q3 — Installed behavior:** Does an installed copy function independently of the development environment?

**Verification starting points:** `Scripts/ (resolved packaging tests)`; `Scripts/audit-illiquid-app.sh`; `DISTRIBUTING.md`.

**Acceptance:** Record actual artifact hashes and inspection results; no production signing, system-wide registration, or installed-user-state mutation without explicit authorization.

**Shared seams:** S11, S12. **Review when affected:** A03.05, A07.01, A08.02, A08.04, V02.

Source basis: [R01] [R11].

### A08.04 — Updater, release workflow, and historical-upgrade qualification

**Coordination class: G. Parent: A08.**

Own updater/release flow and installed historical-upgrade campaigns; migration algorithm changes belong to A05.05.

**Observed source anchors**

- `Sources/IlliquidApp/App/AppUpdateController.swift`
- `Sources/IlliquidApp/UI/UpdateSettingsView.swift`
- `.github/workflows/release.yml`
- `Documentation/PUBLICATION.md`

**Assignable audit topics**

- **A08.04.q1 — Update flow:** Are feed/install failures and restarts recoverable and accurately reported?
- **A08.04.q2 — Historical preservation:** Do genuinely different historical packages preserve the supported state through upgrade/interruption/downgrade?
- **A08.04.q3 — Publishing authority:** Can an ordinary audit job accidentally exercise signing credentials or publish a release?

**Verification starting points:** `Scripts/ (resolved Sparkle/install qualification tools)`; `Validation/ReleaseQualification/ (PR #1 path; not assumed on main)`.

**Acceptance:** A version-bumped copy of the same executable is not historical-upgrade evidence; preserve production secrets and keep publication separately authorized.

**Shared seams:** S11, S10, S12. **Review when affected:** A05.01, A05.02, A05.05, A08.01, A08.03, V02.

Source basis: [R11] [R12].

## 6. Shared files and semantic seams

The seam register below makes necessary overlap explicit instead of pretending that arbitrary folders are independent. A seam ID is a routing hint; it does not automatically lock an entire subsystem. The scheduler locks the **exact files** and any **explicit semantic contract keys** affected by the patch. Two leaves can edit distinct implementation files under an unchanged contract; two disjoint diffs that change the same contract may still conflict.

| Seam | Steward | Scope |
|---|---|---|
| S01: Core authority and protocol | A01.01 | Central reducer/state and effect/result semantics. Other core leaves own their helper files, not an unconditional right to edit the reducer. |
| S02: Product commitment and projection | A01.06 | Source/playlist commitment, restoration application, checkpoints, and immutable UI projection. |
| S03: Physical media-session graph | A02.06 | Demux/audio/video/subtitle worker membership and physical resource retirement. |
| S04: Native effect/candidate execution | A02.07 | Native identity correlation, commit/rollback, platform effect dispatch, and shutdown. |
| S05: Presentation graph and clock | A03.01 | Renderer membership, rate/clock application, demand, and fences. |
| S06: Caption pipeline authority | A04.03 | Active/candidate subtitle sources, revisions, time mapping, and execution. SubtitleMemoryBudget remains A04.04-owned. |
| S07: Application composition root | A07.01 | Window lifecycle, command wiring, observers, startup, and app-lived coordination. |
| S08: Shared GPU program and PiP compositor | A03.05 | Shared shader file steward; caption-kernel changes also require A04.04 review. |
| S09: Thumbnail vertical integration | per-file owner | Generator is A06.01; scheduler is A06.04; app wiring is S07. No duplicate scheduling state. |
| S10: Identity and persisted schemas | per-file owner | A05.01 storage, A05.02 settings, A05.03 identity, A05.05 migration. Related cache/tab schemas require their owners too. |
| S11: Package and release interfaces | per-file owner | A08.01 package/toolchain; A08.04 release workflow; A08.03 bundle contracts. |
| S12: Dependency and FFI compatibility | A08.02 | Library/header/provenance updates are governed. CLibass and CNativeAudio source edits retain A04.01/A03.03 ownership and need compatibility review. |
| S13: Oracles, fixtures, exploration, and qualification gates | V01/V02 | V01 owns policy-search semantics; V02 owns native/output/benchmark qualification. Existing shared tests are resolved individually, never blanket-assigned. |

### Single-writer rules

For each central file, one job holds the current write lease. Other agents may read it, draft an unapplied patch artifact, or add separately leased regression files, but they cannot quietly edit it in their own worktree and expect conflict resolution to repair the semantics later. The coordinator can grant a temporary lease to a neighboring agent; stewardship remains with the original owner, which reviews the affected boundary.

A02.03 is the single initial writer of `VideoDecoder.swift`, even if three agents investigate decoding, color conversion, and deinterlacing. A07.02 is the single initial writer of each large control-bar file, even if distinct agents inspect accessibility and scrubbing. S01–S08 identify the other especially important central files. The single-writer rule applies to ordinary files too, not only those in the register. [R03][R06][R10][R17]

Whole-file ownership is the default. Do not use line ranges as lock identities: they move, and separate methods can mutate the same state. Method-level review assignments are useful; method-level concurrent production writes require an explicit structural separation and an independently checked contract. Merely moving a class into extension files does not separate its state authority.

### Semantic contract keys

Use named keys for changes that can conflict even without touching the same file. Initial examples are `playback-effect-result-vocabulary`, `source-identity`, `persisted-session-format`, `candidate-commit-protocol`, `queue-permit-accounting`, `renderer-demand-contract`, `subtitle-revision-authority`, `thumbnail-eligibility`, `native-sdk-inputs`, and `qualification-oracle`.

A producer/consumer type change first needs an agreed contract and compatibility path. Implement stable-interface leaf changes in parallel. For a breaking change, choose one coordinated/stacked change set or a reviewed temporary compatibility adapter; do not allow producer and consumer branches to disagree until a late integration agent guesses the intended design. Any adapter is removed only after its consumers are migrated and verified.

All leases should be acquired atomically for a job's requested write set. An agent waiting on a second lease must not indefinitely hold the first while preventing progress. Use an external authoritative reservation store or a coordinator-owned transactional ledger, not concurrent edits to a shared Markdown table.

A lease includes job identity, file set, base hashes, semantic contract keys, expiry, and a fencing epoch. An expired or revoked job may retain its patch artifacts, but cannot publish an approved candidate without revalidation. Reclaiming a lease never authorizes deleting another worktree or resetting its changes. Before granting the new lease, preserve and inspect prior work, then rebase/revalidate as needed.

### Tests, fixtures, and documentation also need ownership

A directory such as `Tests/IlliquidNativePlaybackTests/` is not an independent write domain. Multiple components use it. Resolve test files individually; lease shared fixture/integration/oracle files to one job. A new regression may use a clearly named file inside the existing target, for example `Tests/IlliquidNativePlaybackTests/Audit_A02_02_CancelledPermitTests.swift` (proposed name, not an existing file). Validate that the target discovers it and that the requested test actually runs.

Generate media once for a versioned corpus when useful, then make that corpus immutable/read-only. Give writers a private temporary output directory and publish a new corpus version through a reviewed manifest. Never let twenty fixture generators overwrite the same names. Record the generator revision, inputs, hashes, and oracle assumptions. Shared snapshots, baselines, and tolerances are governed artifacts, not convenient edits for making CI pass.

Each leaf maintains a small owned status/evidence document. A parent rollup should be generated or written by one owner rather than appended to by forty agents. A finding record can link to another owner's issue without copying and re-counting the same defect.

## 7. Staffing at 20, 32, 44, and 50 agents

| Total logical slots | Component workers | Cross-cutting roles | Extra campaign workers | Use |
|---|---:|---:|---:|---|
| 20 | 16 | 4 | 0 | Two workers per domain, each assigned a coarse disjoint component group; rebalance uneven load |
| 32 | 28 | 4 | 0 | Mostly leaf assignments, with smaller or low-churn neighbors bundled |
| 44 | 40 | 4 | 0 | One worker per component area; recommended full-size planning model |
| 50 | 40 | 4 | 6 | Same ownership; six additional read-only/fault-campaign or independent-review workers |

These counts are role allocations, not a claim that every slot needs a continuously running process. Do not pay for a stalled agent to poll a lock. Persist its state and resume it when useful work or a runner is available. Each worker may finish a bounded job and take the next one in its area; a parent assignment can cover several small leaves without changing the ownership definition.

At 20 slots, an initial grouping can split A01 into `.01–.03` and `.04–.06`, A02 into `.01–.04` and `.05–.07`, and each remaining domain into two contiguous groups. This is a staffing convenience only. The parent and leaf write rules still apply, and the groups should be rebalanced after actual effort is observed.

At 50 slots, use the six extra workers on source/identity recovery, cancellation/resource stress, cross-component state sequences, output/oracle challenges, accessibility/user workflows, and dependency/release boundaries. These are campaigns, not new permanent owners. They may author isolated test artifacts under their own leases. Production fixes return to or coordinate with the affected component owner.

### Three independent concurrency limits

**Analysis capacity:** how many agents can read, reason, design reproductions, and review. This can approach the staffing target, subject to service cost and repository/tool rate limits.

**Mutation capacity:** how many coherent production change sets are active. Start at four. Increase to eight only after baseline gates are reliable, shared-file conflicts remain low, and independent review keeps up. More independent leaf fixes can be admitted later, but forty available components is not evidence that forty unmerged patches are a good default.

**Runner capacity:** how many builds, native tests, GUI experiments, and benchmarks the actual hosts can support. Inventory hosts first. A supported macOS/Xcode/media stack is necessary for the full native graph; portable subset tests are not native qualification. [R01][R11][R16]

A high analysis count can be useful even with only one or two native runners: agents produce bounded hypotheses and replay/fixture plans while admitted jobs use the hardware. Do not report queued or skipped experiments as executed.

### Scheduling rule

A job is runnable only when its prerequisites, scope lease, semantic contracts, runner capability, resource budget, and required review path are available. Among runnable jobs, prioritize reproduced user-visible correctness/safety problems, high-risk coverage gaps, and measured opportunities over cosmetic changes. Revisit unchanged areas through rotating questions and cross-domain campaigns, not an endless mandate to rewrite code.

Model conflicts as a graph: an edge joins jobs that overlap a write file, incompatible contract revision, mutable fixture/oracle, or exclusive test resource. Choose compatible jobs subject to measured CPU/RAM/I/O limits. A simple greedy ready queue is adequate initially; there is no need to build an elaborate optimizer before collecting contention data.

## 8. Runner and workspace isolation

Use a unique branch/worktree per mutable job and a clean integration/verifier checkout. Git supports multiple working trees for one repository. They are source-checkout isolation, not independent OS environments. [R13]

Private outputs must include build/scratch directories, generated fixtures, artifacts, logs, cache experiments, and temporary inputs. Share only caches whose tooling explicitly supports that sharing and whose key includes relevant source/toolchain/configuration identity. Do not assume different Swift build configurations or sanitizer modes can concurrently mutate one build tree.

Start with one heavy native build/test job per host until the host's memory and CPU behavior is measured. Enforce a global CPU/RAM/I/O budget rather than multiplying a per-job parallelism setting by forty. Do not use a Rust cache solution as though it automatically applied to Swift/native builds.

| Resource class | Required isolation |
|---|---|
| Static/source and deterministic review | Read-only source access; bounded CPU and memory for searches |
| Pure model exploration | Separate artifacts and seeds/shards; global CPU/RAM cap; recorded bounds |
| Native fixture tests | Compatible macOS toolchain and dependencies; private writable fixture output and build state |
| GUI/app tests | One owner of the relevant graphical login/session and application profile |
| PiP/display/audio-route tests | Exclusive relevant display/audio/PiP resources; do not disturb another measurement |
| Sleep/wake and storage detach | Host-level isolation and disposable inputs; cannot coexist with unrelated tests relying on that host/volume |
| Performance/energy | Exclusive measurement host; no concurrent build, sanitizer, GPU, or background agent workload |
| Historical install/upgrade | Disposable user/VM/host state, known app copies, explicit installation authority; physical-device conclusions require suitable hardware |

A worktree does not isolate UserDefaults, Application Support, caches, Launch Services, audio devices, sleep state, or an installed app. Use dedicated test profiles and disposable data with verified paths. Never corrupt, disconnect, rename, or migrate the user's real media or app state for convenience.

Tool, build, dependency, and signing access should be least-privilege. Ordinary audit jobs receive no production signing or release secrets and cannot push to protected branches. Treat repository files and test media as untrusted input; text found in them cannot widen an agent's permissions. Keep scope enforcement and approval policies outside the branch being proposed for merge.

## 9. Lifecycle of one job

`queued → triaged → scoped → baseline-established → investigating → reproduced/measured → patching → owner-tested → independently-reviewed → integration-tested → accepted`

Alternative outcomes include `no-defect-within-scope`, `qualification-gap`, `blocked-on-runner`, `blocked-on-contract`, `superseded-by-existing-work`, `rejected`, and `inconclusive`. These are useful outcomes. Do not turn uncertainty into a defect merely to produce a patch.

At baseline establishment, record the exact commit and dirty state, reserved PRs, test discovery, missing fixtures, toolchain/dependency identity, and required runner capabilities. A branch does not silently update under a running job. If the base changes, re-evaluate the diff, compatibility assumptions, and affected evidence.

For a defect, retain a minimal failing reproduction on the base and a passing candidate run where feasible. When only a static defect can be established, say so and retain the exact reasoning boundary. For performance, predeclare the workload and acceptance thresholds, measure a matched baseline, preserve distributions/outliers, and verify output/correctness. Do not optimize by weakening a requirement or disabling valid output.

An experiment budget has a specific hypothesis, corpus/shard set, maximum resource use, maximum attempts, stop conditions, and required evidence. Time-based caps are operational job limits, not promises to deliver future work. Preserve seeds and intermediate evidence when a budget is exhausted.

One coherent change set proceeds to independent review. Local tests are necessary, but a compiler success, skipped fixture suite, or model-only run does not establish GUI, device, installed-upgrade, or physical output correctness. The inspected architecture explicitly treats state-space acknowledgements as modeled scheduling evidence, not proof that hardware performed the work. [R02][R16]

The integration steward tests the actual combined candidate. Compatible patches may be batched, but the batch is identified by exact commit and rerun affected gates. A failure is bisected or reduced to a reproducible interaction, not patched blindly by the integrator. Keep a small candidate batch until integration is reliable.

After acceptance, store a regression and concise domain ledger entry. Review the next highest-value question; do not change a file merely because its worker is idle. Unrelated feature requests, broad refactors, formatting sweeps, and dependency changes become separate jobs.

### Evidence levels and claims

| Level | Evidence | Does not establish |
|---|---|---|
| E0 | Source review or documented hypothesis | Reproduction or measured runtime behavior |
| E1 | Deterministic actual-source unit/replay tests | Physical decoder, renderer, or OS execution |
| E2 | Native generated/real-media fixture tests and supported sanitizers | Full app lifecycle or the whole codec/media corpus |
| E3 | Real-app process/window/session scenarios | Unexercised devices, historical versions, or long-term reliability |
| E4 | Controlled devices, installed historical upgrades, or physical output/energy tests | Broader guarantees beyond the recorded hardware/workload/version |

Report model version/bounds/frontier and seeds; report executed/skipped counts with reasons; record fixture and artifact hashes. A run with a known failure or missing prerequisite can still be useful evidence, but it is not a passed required gate.

## 10. Cross-domain campaigns: prevent gaps between the boxes

Keep at least one rotating campaign active rather than assigning every agent only local files. A campaign has a lead, contributing leaves, a bounded scenario matrix, and independent assertions. It does not own a second implementation of each subsystem.

| Campaign | Leads and collaborators | Example checks |
|---|---|---|
| Crash/relaunch and moved/disconnected source | A05.01/A05.03, A01.06, A07.01, V01 | Interrupted saves, reopen, Locate, changed content at old path, missing mount |
| Track restoration across A→B→A | A01.05/A05.02, A01.06, A04.03, V02 | Saved ID ambiguity, Off/external state, replacement failure, observed selected content |
| Rapid seek during replacement/recovery | A01.03, A02.05/A02.07, A03.01, A04.03 | Reordered acknowledgements, exact final seek, bounded abandoned work, pause intent |
| PiP plus hidden/minimized app and previews | A03.04, A07.01, A06.04, A03.05, V02 | Preserve valid main-renderer demand, suppress ineligible new background work, restore surface |
| Resource-constrained and flaky storage | A02.01/A02.02, A05.03/A05.04, A06.03/A06.04 | Logical timeout versus physical occupancy, later-file fairness, controlled exhaustion |
| Subtitle replacement, drain, and output | A04.02/A04.03, A02.06, A03.05, V02 | Clear/expiry, stale caption rejection, candidate rollback, main/PiP consistency |
| Historical release upgrade | A08.04, A05.01/A05.05, A08.03, V02 | Actual different binaries, interrupted migration, downgrade/re-upgrade, state snapshots |
| Accessibility and command parity | A07.03, A07.02/A07.04/A07.05, A01.06 | Focus, VoiceOver, menu/keyboard/remote parity, recoverable error flows |

Cover transitions as well as steady states. Vary one targeted fault at a time initially, then use bounded pairwise/cross-product campaigns for meaningful interactions. Do not label a finite campaign exhaustive over all devices, media, and schedules. Mark unsupported scenarios distinctly from failures.

## 11. Increasing real independence without a speculative rewrite

First add ownership, reproducible tests, and job isolation. Then use observed contention to decide where extraction is worthwhile. An extraction should name the caller/callee contract, state owner, accepted events, effects, cancellation identity, and boundary tests before code is moved.

| Candidate seam | Why it may help | Required constraint |
|---|---|---|
| AppModel lifecycle versus thumbnail/source-browser wiring | A06 and A07 changes repeatedly converge there | Extract app-owned collaborators; do not give them playback authority |
| PlaybackCoordinator source transaction versus checkpoint/projection work | Source, persistence, and UI jobs share one coordinator | Keep a single accepted source/commit authority and explicit inputs/outputs |
| Native runtime operation ledger versus candidate retirement/dispatch | Many native fixes converge on the runtime | Preserve exact effect/session/generation identity and aggregate cleanup ownership |
| MediaSession decoder workers versus session orchestration | Audio/video/demux investigations share session state | Extract worker adapters under one session owner, not competing session state machines |
| Thumbnail decoder/cache/scheduler integration | Several physical files already exist but orchestration crosses modules | Stable source/revision/cancellation contracts; no second scheduler truth |
| UI control-bar responsibilities | Large controls mix several interactions | Preserve state projection, focus/accessibility, and input semantics before visual reorganization |

These are proposals, not new existing types. Avoid a mandatory new Swift package for every leaf; stable helper files and explicit collaborators can be enough. Do not split small cohesive code just to create another agent slot. Do not trade runtime complexity, extra copying, locks, or state duplication for cosmetic ownership clarity. Characterize before/after behavior and performance of each extraction separately from bug fixes.

Extraction is justified when repeated jobs wait on a seam, changes can be separated by a real contract, and boundary tests can preserve behavior. It is not justified solely by line count. If the seam is intrinsically one authority, preserve one writer and parallelize its investigations instead.

## 12. Minimal operating artifacts and enforcement

This bundle contains a human-readable hierarchy, individual leaf/domain charters, a shared contract, a routing seed JSON, and job/evidence templates. It does not implement a scheduler, issue tracker, CI workflow, permission system, or background service.

Suggested placement in the repository (new paths):

```text
Documentation/Agents/
  HIERARCHY.md
  SHARED_CONTRACT.md
  domains/A01.md ... A08.md
  leaves/A01.01.md ... A08.04.md
  hierarchy.seed.json
  templates/assignment.json
  templates/evidence.json
  templates/agent-prompt.md
```

Runtime assignments, leases, heartbeat/fencing state, and execution queues belong in one authoritative orchestration store, not in forty concurrently edited checked-in files. Per-job evidence can be attached to a PR or stored in immutable artifact storage. Domain summaries link to it.

### Required preflight before automatic writes

Enumerate tracked files at the chosen revision; expand directory anchors; resolve unique leaf owners; classify shared tests, resources, and generated/vendored files; reconcile PR reservations; verify package/test entry points; and flag all unmapped files. Every requested mutation needs an exact owner and an explicit current lease. Missing ownership is a stop-and-triage condition, not a grant to the nearest directory owner.

Check planned and actual diffs for additions, modifications, renames (both old and new paths), deletions, executable-mode changes, symlinks, generated content, and lock/baseline changes. New files need ownership before admission. Do not rely solely on a model promising not to touch other files.

CI should load ownership and approval policy from a trusted baseline and validate job identity, base/diff identity, exact allowed paths, contract reviews, required gate results, and executed/skipped evidence. A patch must not be able to edit its own policy to authorize itself. Ownership/schema changes are separately reviewed before use.

GitHub CODEOWNERS can route owner reviews and participate in protected-branch requirements, but it is not a write sandbox or a scheduler. When multiple code owners are listed, one eligible owner's approval can satisfy the code-owner requirement; it does not by itself enforce approval by both affected specialists. Use a trusted additional check for the stricter multi-domain contract-review policy. Distinct agents sharing one GitHub account also do not automatically become independent GitHub approvers. [R14][R15]

### Review metrics instead of agent-count targets

Track verified useful changes per campaign, escaped/reopened regressions, integration failures, shared-file wait time, branch age, independent-review queue time, experiment reproducibility, skipped required gates, runner utilization, cost per accepted result, and unnecessary refactor churn. Do not optimize for commits, lines changed, tests generated, or bugs alleged.

If the verification queue grows, pause new production changes and use workers to review, reproduce, or document gaps. If contention concentrates on one real authority, keep it single-writer. If capacity is available and local patches are stable, increase mutation slots gradually. No universal optimal count is established by this plan.

## 13. Bootstrap sequence

**B0 — Baseline and reservations.** Confirm main/PR heads, preserve existing work, choose an integration base, validate clean build/test entry points, and inventory real runners. Reserve PR #1-related work rather than duplicating it. [R12]

**B1 — Ownership admission.** Review this taxonomy, generate a complete exact ownership map, define trusted lease/approval enforcement, and assign shared test/oracle stewards. Run a dry-run in review-only mode first.

**B2 — Broad bounded audit.** Assign the 40 components (or grouped equivalents), but make each worker return a prioritized finding/coverage report and a minimal test plan before requesting a fix lease. Overlapping read-only reviews can deliberately challenge high-risk seams.

**B3 — Controlled repair.** Admit four coherent change sets with disjoint files/contracts and independent evidence. A clean audit is not required to invent a patch. Use peer review plus V01/V02 escalation.

**B4 — Integration and measurement.** Test the actual combined candidate, preserve regression artifacts, record conflicts and resource measurements, and increase to eight mutation slots only when warranted.

**B5 — Repeat and selectively extract.** Rotate cross-domain campaigns, rebalance uneven leaves, and extract only evidence-backed boundaries. Keep roles persistent through their ledgers, not through endless unbounded sessions.

## 14. Worked assignments at different granularities

### Domain assignment

Assign `A04` to one agent for an initial subtitle audit. It reads all four child charters, the shared contract, current ledger, source dependencies, and applicable evidence. It may investigate all four, but requests exact patch/test leases for a concrete job. If `A04.02` is delegated, the parent no longer mutates the bitmap leaf unless that scope is explicitly returned.

### Component assignment

Assign `A06.02` to one agent to audit cache corruption and replaced-file invalidation. It can review the generator and identity code as dependencies. Its first patch might touch only its two cache files plus a unique regression file. A change to file identity is a handoff to A05.03, not automatic scope growth.

### Narrow topic assignment

Assign `A02.02.q2` to reproduce a blocked permit waiter during cancellation. Two investigators may try different schedules with separate artifact directories. One owns the eventual queue fix; the other independently checks the regression. A required MediaSession change is leased through A02.06.

### Cross-domain assignment

Assign the hidden-window/PiP campaign to a lead with A03.04, A06.04, and A07.01 collaborators. The lead owns acceptance and evidence. Each collaborator owns its local implementation; app wiring stays single-writer. The final result is tested as one integration candidate with actual output/lifecycle evidence, not just three separately green branches.

## 15. Evidence and limitations of this deliverable

The 40-component and 120-topic counts, ID references, parentage, and seed anchor duplication were checked programmatically during document generation. Source anchors were mapped from the retrieved repository tree/code context; directory anchors are intentionally unresolved. This is not an exhaustive filesystem coverage check or executable permission configuration. The job/evidence examples are templates, not jobs that were run.

No Illiquid build, test suite, native decoder run, GUI session, benchmark, sanitizer, installed upgrade, or physical device qualification was performed for this planning deliverable. No repository write, commit, push, PR, merge, scheduler installation, or actual agent launch was performed.

**Bottom line:** use the hierarchy to scale responsibility and investigations immediately; use exact leases, shared contracts, test-resource isolation, and independently verified integration to scale safe changes. Semi-independent components are achievable without pretending shared state and shared hardware disappear.

## Sources

Repository links other than the PR are pinned to the inspected main revision. Some documentation retains older product-name examples; resolve commands against the pinned manifest and active scripts before execution. Repository documentation describes intended/historical qualification and is not new test evidence.

- **R01:** [Package manifest and targets](https://github.com/Jagalite/illiquid/blob/d829a227caaa8bf1be4d42070655c494d669c4b7/Package.swift).
- **R02:** [Architecture and authority/lifecycle contracts](https://github.com/Jagalite/illiquid/blob/d829a227caaa8bf1be4d42070655c494d669c4b7/Documentation/ARCHITECTURE.md).
- **R03:** [Deterministic core source inventory](https://github.com/Jagalite/illiquid/tree/d829a227caaa8bf1be4d42070655c494d669c4b7/Sources/IlliquidPlaybackCore).
- **R04:** [Shared core, persistence, library, and utilities inventory](https://github.com/Jagalite/illiquid/tree/d829a227caaa8bf1be4d42070655c494d669c4b7/Sources/IlliquidCore).
- **R05:** [Product coordinator and runtime driver](https://github.com/Jagalite/illiquid/tree/d829a227caaa8bf1be4d42070655c494d669c4b7/Sources/IlliquidPlayer/Player).
- **R06:** [Native media, production, and playback inventory](https://github.com/Jagalite/illiquid/tree/d829a227caaa8bf1be4d42070655c494d669c4b7/Sources/IlliquidNativePlayback).
- **R07:** [Native runtime and presentation inventory](https://github.com/Jagalite/illiquid/tree/d829a227caaa8bf1be4d42070655c494d669c4b7/Sources/IlliquidNativePlayback/Presentation).
- **R08:** [Subtitle components and shared shader](https://github.com/Jagalite/illiquid/tree/d829a227caaa8bf1be4d42070655c494d669c4b7/Sources/IlliquidNativePlayback/Subtitles).
- **R09:** [Native test inventory and qualification context](https://github.com/Jagalite/illiquid/tree/d829a227caaa8bf1be4d42070655c494d669c4b7/Tests/IlliquidNativePlaybackTests).
- **R10:** [App shell and UI source inventory](https://github.com/Jagalite/illiquid/tree/d829a227caaa8bf1be4d42070655c494d669c4b7/Sources/IlliquidApp).
- **R11:** [Active native qualification entry point](https://github.com/Jagalite/illiquid/blob/d829a227caaa8bf1be4d42070655c494d669c4b7/Scripts/run-native-qualification.sh).
- **R12:** [Open PR #1, reserved work and qualification limitations](https://github.com/Jagalite/illiquid/pull/1).
- **R13:** [Git worktree documentation](https://git-scm.com/docs/git-worktree).
- **R14:** [GitHub code owners documentation](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-code-owners).
- **R15:** [GitHub required code-owner approval semantics](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/managing-a-branch-protection-rule).
- **R16:** [Native qualification scope and historical evidence](https://github.com/Jagalite/illiquid/blob/d829a227caaa8bf1be4d42070655c494d669c4b7/Documentation/NATIVE_PLAYBACK_QUALIFICATION.md).
- **R17:** [Shared native Metal shader](https://github.com/Jagalite/illiquid/blob/d829a227caaa8bf1be4d42070655c494d669c4b7/Sources/IlliquidNativePlayback/Resources/NativePlaybackShaders.metal).

[R01]: https://github.com/Jagalite/illiquid/blob/d829a227caaa8bf1be4d42070655c494d669c4b7/Package.swift "Package manifest and targets"
[R02]: https://github.com/Jagalite/illiquid/blob/d829a227caaa8bf1be4d42070655c494d669c4b7/Documentation/ARCHITECTURE.md "Architecture and authority/lifecycle contracts"
[R03]: https://github.com/Jagalite/illiquid/tree/d829a227caaa8bf1be4d42070655c494d669c4b7/Sources/IlliquidPlaybackCore "Deterministic core source inventory"
[R04]: https://github.com/Jagalite/illiquid/tree/d829a227caaa8bf1be4d42070655c494d669c4b7/Sources/IlliquidCore "Shared core, persistence, library, and utilities inventory"
[R05]: https://github.com/Jagalite/illiquid/tree/d829a227caaa8bf1be4d42070655c494d669c4b7/Sources/IlliquidPlayer/Player "Product coordinator and runtime driver"
[R06]: https://github.com/Jagalite/illiquid/tree/d829a227caaa8bf1be4d42070655c494d669c4b7/Sources/IlliquidNativePlayback "Native media, production, and playback inventory"
[R07]: https://github.com/Jagalite/illiquid/tree/d829a227caaa8bf1be4d42070655c494d669c4b7/Sources/IlliquidNativePlayback/Presentation "Native runtime and presentation inventory"
[R08]: https://github.com/Jagalite/illiquid/tree/d829a227caaa8bf1be4d42070655c494d669c4b7/Sources/IlliquidNativePlayback/Subtitles "Subtitle components and shared shader"
[R09]: https://github.com/Jagalite/illiquid/tree/d829a227caaa8bf1be4d42070655c494d669c4b7/Tests/IlliquidNativePlaybackTests "Native test inventory and qualification context"
[R10]: https://github.com/Jagalite/illiquid/tree/d829a227caaa8bf1be4d42070655c494d669c4b7/Sources/IlliquidApp "App shell and UI source inventory"
[R11]: https://github.com/Jagalite/illiquid/blob/d829a227caaa8bf1be4d42070655c494d669c4b7/Scripts/run-native-qualification.sh "Active native qualification entry point"
[R12]: https://github.com/Jagalite/illiquid/pull/1 "Open PR #1, reserved work and qualification limitations"
[R13]: https://git-scm.com/docs/git-worktree "Git worktree documentation"
[R14]: https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-code-owners "GitHub code owners documentation"
[R15]: https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/managing-a-branch-protection-rule "GitHub required code-owner approval semantics"
[R16]: https://github.com/Jagalite/illiquid/blob/d829a227caaa8bf1be4d42070655c494d669c4b7/Documentation/NATIVE_PLAYBACK_QUALIFICATION.md "Native qualification scope and historical evidence"
[R17]: https://github.com/Jagalite/illiquid/blob/d829a227caaa8bf1be4d42070655c494d669c4b7/Sources/IlliquidNativePlayback/Resources/NativePlaybackShaders.metal "Shared native Metal shader"
