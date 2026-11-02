# Production migration to Statelessness

Status: implemented on branch `statelessness/production-migration` (2026-11-02).
Phase evidence, the boundary ledger and the discrepancy register are in
[StatelessnessProduction/STATUS.md](StatelessnessProduction/STATUS.md). This
document remains the plan of record; its source references describe the
pre-migration code at `935604b6`. Prepared 2026-11-01.

## Objective and completion boundary

The scope follows Illiquid's existing functional-core / imperative-shell boundary. Statelessness takes over the functional core: authoritative model state, transition execution, checks and execution lifecycle. Illiquid supplies its playback domain definitions directly to that framework. The existing imperative shell continues decoding, I/O, presentation and effect execution. This is replacement of the core within the established architecture, not a migration of media mechanisms into Statelessness.

Replace Illiquid's legacy playback state-machine core and execution engine with a native Swift Statelessness production model and library-owned execution session. Delete `PlaybackCore`, `PlaybackModelRuntime`, and the `IlliquidPlaybackCore` product/target once their callers and contracts have migrated. Production playback, verification, and replay must execute the same model transition definition. A model whose step still delegates to `PlaybackCore.update` does not satisfy this goal.

This extends the completed [verification migration](STATELESSNESS_SWIFT_MIGRATION.md), whose explicit scope preserved the production core. Its [status and receipts](StatelessnessMigration/STATUS.md) remain historical evidence for that migration, not proof that this production migration has passed.

Playback semantics necessarily remain application code: Statelessness accepts application-defined states, inputs, outputs, and transitions. Those definitions become the native model, rather than a separate engine behind an adapter. FFmpeg decoding, Metal presentation, audio output, filesystem access, and UI remain mechanism adapters. Replacing those media implementations is not implied by replacing a state-machine framework. `IlliquidCore`, the broader application data/utilities module, is distinct from `IlliquidPlaybackCore` and is not slated for wholesale deletion.

## Inspected baseline and evidence limits

- Illiquid local `main`: `935604b619b32e1706c718e981e22f8f74223de2`; clean at analysis start.
- Statelessness dependency in `Package.swift`: `3fbdca7c49be3cf32da613f887a7f149e0b97087`.
- Local `/Volumes/seed2/Projects/stateless` HEAD matches that pin. Its status contains untracked validation evidence; this analysis did not alter it.
- Analysis is source inspection. No new compilation, test execution, performance measurement, or live UI qualification was performed.
- Existing migration receipts report completed verification parity and retirement, with explicitly bounded/incomplete exploration cases. Reuse their fixtures, but rerun qualification on the new production model.

### What is implemented now

| Area | Current implementation | Consequence |
| --- | --- | --- |
| Dependency | [Package.swift](../Package.swift) gives Statelessness to the state-space target and its tests | Production core has no Statelessness dependency |
| Live execution | [PlaybackRuntimeDriver](../Sources/IlliquidPlayer/Player/PlaybackRuntimeDriver.swift) owns `PlaybackModelRuntime`, sends commands/results, then dispatches effects | Live player still runs the legacy engine |
| Engine wrapper | [PlaybackModelRuntime](../Sources/IlliquidPlaybackCore/PlaybackModelRuntime.swift) owns core state indirectly, sequence/time, pending effects, replay steps and helper shrinking | Generic runtime and verification helpers remain outside Statelessness |
| Transition authority | [PlaybackCore](../Sources/IlliquidPlaybackCore/PlaybackCore.swift) implements event dispatch, guards, state mutation, effect registration, completion, and invariant failure handling | Merely switching imports cannot retire the core |
| Verification | [PlaybackStatelessnessModel](../Sources/IlliquidPlaybackStateSpace/Statelessness/PlaybackStatelessnessModel.swift) wraps search state/actions; [PlaybackModelTransitions](../Sources/IlliquidPlaybackStateSpace/PlaybackModelTransitions.swift) still constructs `PlaybackCore` and calls `update` | Verification uses Statelessness algorithms but still verifies the legacy production transition function |
| Native mechanisms | [NativePlaybackRuntime](../Sources/IlliquidNativePlayback/Production/NativePlaybackRuntime.swift) executes effects; driver also handles persistence, playlist and coalesced seeks | These execution boundaries must survive the migration and be checked for duplicate policy |
| Architecture guard | [IlliquidArchitectureCheck](../Validation/IlliquidArchitectureCheck/main.swift) depends on the old core | Update the guard to enforce the new ownership, not preserve obsolete dependencies |

### What Statelessness supplies, and what needs extending

At the pinned revision, `swift/Sources/Statelessness/Model.swift` supplies `Model<State, Input, Output>` and `Transition`, cloning contracts, checks, equality, hashing and optional codecs. `CheckedResults.swift` supplies `checkInitial` and `checkTurn`: they check supplied state/transitions and **do not execute the reducer**. `Recorder.swift` supplies bounded observation of application-executed transitions, including `observeChecked`; it likewise does not execute effects or reducers. `Execution.swift` supplies finite recording/replay, and the S1–S5 modules supply graph exploration, progress, reduction and continued-failure evidence.

These are useful foundations, but the inspected public APIs do not establish a persistent production session with atomic state commit, reentrancy control and explicit output handoff. The internal `perform` helper is not a public application runtime. Campaign runtimes concern verification campaigns and should not be assumed to implement a player event loop.

Add the missing reusable execution contract upstream. Do not re-request the completed S1–S6 verification work, and do not turn `record` into an indefinitely retained production loop.

## Target architecture

Names below are proposed, not existing APIs.

1. **Statelessness execution session** owns the current model state, turn sequence, transition invocation, isolation, check execution and commit result. It has no media knowledge and performs no native effects.
2. **`IlliquidPlaybackModel`** owns the concrete playback state/events/effects, deterministic playback rules, identity/authority rules, invariants, and UI projection. It depends on native Swift Statelessness and, where needed, `IlliquidCore` value types. It has no player/native-runtime dependency.
3. **`IlliquidPlayback`** defines the transport-facing runtime protocols and requests using the new model types.
4. **Player runtime host** serializes inputs on the current MainActor boundary, submits them to the Statelessness session, publishes snapshots, and hands committed effects to adapters. It contains no alternative reducer or authoritative copy of playback state.
5. **Native adapters** execute effects and deliver tagged results. Opaque URLs, device handles, decoder objects, Tasks and callbacks stay outside deterministic state.
6. **`IlliquidPlaybackStateSpace`** adds bounded environments, search actions, canonical quotient, progress/reduction policies and qualification settings around the same production model. Search abstractions never become live playback state.

Dependency direction: Player → Playback / NativePlayback / PlaybackModel; Playback and NativePlayback → PlaybackModel; StateSpace → PlaybackModel + Statelessness; PlaybackModel → Statelessness + application value types. Statelessness never imports Illiquid.

### The production model

Use a model equivalent to `Model<PlaybackState, PlaybackEventEnvelope, PlaybackOutput>`. `PlaybackState` contains concrete playback state, outstanding effects, completion identity, leases and lifecycle. `PlaybackOutput` carries ordered effect intents and any domain observation required to preserve detailed disposition and invariant evidence. Keep the richer playback disposition alongside the library's accepted/rejected/ignored classification.

The step callback directly implements the migrated playback rules and returns `Transition`. It must not create `PlaybackCore`, call `update`, or maintain another mutable engine instance. Decompose rules into pure functions over value state (loading, seek, track selection, subtitles, synchronization, recovery, drain and shutdown); retaining those playback rules is necessary, retaining their old engine owner is not.

The live input is a concrete envelope, not `SearchAction`. Verification materializes an envelope from a search action and invokes this same model step. Environment-only actions and gate rejection remain explicit observations; they must not manufacture an extra production turn. Update `calledProductionCore` terminology and codecs deliberately, with versioning where serialized values change.

## Upstream production execution contract

Specify and test this contract before changing the live default. A proposed `ExecutionSession` API should support initialization from a model/checkpoint, read-only detached snapshots, and synchronous submission returning a committed turn or an explicit fault. API naming can change; the following behavior cannot be implicit.

| Contract | Required behavior and tests |
| --- | --- |
| One invocation | One input invokes step once; checks, recording and snapshot publication never rerun it. Side-effect-free counting models detect double invocation |
| Commit | Clone/detach input and prior state, execute and check candidate, prepare detached output, then commit state and sequence atomically. A throwing step/check/clone before commit exposes no effects and leaves prior committed state intact |
| Domain rejection | Rejected/ignored inputs can still update diagnostic counters or time, as the current core does. Commit the returned candidate; do not equate rejection with rollback |
| Failed properties | Separate a complete failed check batch from a thrown model error. Preserve Illiquid's explicit invariant-failed state and cleanup behavior; encode safety policy in the playback transition, not a generic guessed rollback rule |
| Sequence | Define initialization, restore and overflow. No silent wrap or repeated terminal sequence. Playback virtual time is an explicit input/domain policy, not a library wall-clock read |
| Reentrancy | Synchronous exclusive access; reject recursive submission or queue it in a bounded host inbox. Commit before notifying observers or dispatching effects. Synchronous completion callbacks become later inputs |
| Concurrency | Keep the model/session actor-confined under Swift 6. Do not add unchecked Sendable to closures or native objects to bypass isolation errors |
| Output handoff | Return committed effects once per successful submission. The host dispatches each once locally; retries/results use stable domain identity. This is not durable exactly-once I/O across process crashes |
| Recording | Optional bounded Recorder integration consumes checked turns. Recorder failure after commit is a diagnostic failure, never an instruction to replay an effect or pretend the transition rolled back |
| Restoration | Replay is effect-free. Restoring playback after restart requires new native resources and authority identities, rather than resending historical outputs to old handles |

Keep full model checking for qualification. If live check sampling is later needed, version it explicitly and never label sampled turns as fully checked. Start with the same safety checks as today's core; changes to failure handling require separately reviewed behavior fixtures.

Upstream fixtures must cover mutable-reference isolation, throwing clones/checks, rejected state changes, sequence exhaustion, recursive submission, failed checks, recorder exhaustion and committed-output ownership. Use independent toy models, not Illiquid-only tests, so this remains a generic capability.

## Concrete retirement map

| Existing source/owner | Destination and retirement action |
| --- | --- |
| `PlaybackCore.swift` | Split domain rules into the production model callback and rule modules. Delete the struct, update entry point, internal orchestration and all calls |
| `PlaybackModelRuntime.swift` | Session ownership/sequencing moves upstream; domain envelope time policy moves into the model/host contract. Delete wrapper and unbounded `steps` accumulation. Replace seeded generator/shrinker helpers with Statelessness `Generate` and shrinking APIs plus application-specific policies |
| `PlaybackCoreState.swift`, `IdentityAndTime.swift`, `EventsAndEffects.swift` | Move value definitions to `IlliquidPlaybackModel`; rename core-specific symbols where needed. Preserve wire semantics or explicitly version codecs |
| `SeekCore`, `TrackSelectionCore`, `SubtitleCore`, `SynchronizationCore`, `RecoveryCore`, `LoadingAndDrainCore` | Port domain state and policies into model modules. They must not retain a hidden instance of the legacy engine |
| `PlaybackInvariants.swift` | Move predicates into model checks; preserve required fail-state transitions and ordered violations. Check callbacks must not mutate state |
| `CompletedPlaybackEffectHistory.swift` | Preserve compact identity tracking as domain storage initially; it is not an execution engine. Test long sessions and serialization so expansion into large sets does not regress memory |
| `PlaybackReplay.swift` | Move necessary canonical value/codec definitions; replace active replay mechanics with Statelessness. Keep historical decoding/conversion only where required by retained fixtures |
| `PlaybackRuntimeDriver.swift` | Replace `model.core` and `model.send` with session access/submission. Keep I/O mapping and host scheduling only; migrate correctness decisions into explicit model state/inputs |
| `PlaybackModelTransitions.swift` | Replace core construction/update with the shared production model callback; preserve gate/environment distinctions and causal result handling |
| Package and consumers | Replace imports/dependencies in Playback, NativePlayback, Player, tests, diagnostics and architecture checks; remove old product and target entirely |

Inventory all tracked references before deletion, including `Validation`, `Tests`, scripts and historical converters. The `Superplayr*` directories are not declared production targets in the inspected manifest; do not infer a second engine from their names or delete unrelated files as part of this work.

## Boundary hazards that must be resolved

- **Ingress authority:** the driver has a `PlaybackRuntimeEventGate`; the core also validates effect authority/context. Document both checks. Share deterministic admission policy between live and verification paths so late callbacks after replacement cannot bypass it. Transport normalization can stay in the host.
- **Effects and acknowledgments:** preserve outstanding-effect registration, ordered emissions, duplicate/stale results, completion requirements, cancellation and lease release. The current model runtime excludes `bestEffortMirror` from pending work; preserve that distinction and test synchronous mirror completions.
- **Relative seek batching:** the driver uses a 40 ms dispatch interval and pending seek state. Represent any acceptance/cancellation/which-seek-wins decision in model state; the host supplies monotonic timer observations and executes the chosen effect. Do not change seek responsiveness accidentally during migration.
- **Native operation transactions:** inspect `NativeOperationTransaction`, `NativeRecoveryController`, runtime metadata and `NativePlaybackRuntime` for decisions based on lifecycle/authority. Move correctness policy into the model; keep decoder/device scheduling and resource ownership in adapters. Track each retained policy with a reason and a test.
- **Invariant failure ordering:** today's core registers effects and checks invariants before returning its transition, and can set lifecycle to `invariantFailed`. Moving checks after commit or suppressing all outputs would change behavior. Freeze actual failed-turn outputs and decide explicitly which cleanup outputs remain legal.
- **State versus projection:** UI snapshots and search canonical keys are projections. Neither may replace the full state used to settle outstanding effects or determine authority.
- **Exhaustion and boundedness:** test identity exhaustion, virtual-time regression, sequence limits, large pending effect sets and long playback. No unbounded replay history in the live session.

## Implementation phases and exit gates

### P0 — Freeze the production contract

Record both revisions, package resolution, source hashes, toolchain and relevant native dependency identities. Inventory every `PlaybackCore`, `PlaybackModelRuntime`, old module import and direct state mutation. Build a boundary ledger for driver/native policy with destination and test.

Capture deterministic input streams and full expected post-state, detailed disposition, ordered effects, snapshot and invariant results from the current core. Cover load/replacement, play/pause/speed, all seeks, tracks, subtitles, buffering/synchronization, recovery, EOF/drain, sleep/wake, stop, shutdown and stale/duplicate/failing results. Include adverse ordering, deadlines, allocation exhaustion and invariant-failed behavior. Preserve the current verification golden fixture independently.

Add three small baseline records to the existing P0 receipt; reuse existing fixtures and runners:

- **Persisted data:** trace disk readers/writers for `PlaybackCoreState` and replay types, including embedded representations. Use one table with format/path pattern, reader/writer, version and compatibility action. Record “no disk consumers found” with the search scope when applicable. Reuse one saved fixture per distinct supported format/version; add a fixture only where coverage is missing. This is a source-level inventory of affected formats, not a scan of users’ media or a general persistence audit.
- **Media manifest:** select a small representative subset of existing qualification media. Record stable names, paths, byte sizes and SHA-256 hashes, including sidecars consumed by the workloads, plus the workload/settings used. Keep files in their existing location; commit the manifest, not copies of large media. Verify hashes before both baseline and candidate runs. Expand the set only when a changed behavior requires additional coverage.
- **Live check cost:** use a short existing event workload to measure current invariant-check and total event-processing cost before porting. The old core already checks invariants; record that baseline and set an explicit incremental latency/CPU budget for Statelessness checks, cloning and optional recording. Use a few repeated runs and retain the command, event count and timing summary. Measure candidate overhead once available in P1/P2 and recheck it in P4; P0 does not require building the new runtime. Investigate duplicate checks or regressions before adding a larger benchmark suite.

Exit: frozen baseline oracle and boundary ledger are reviewable; the three compact records above are present, and comparison fields and live performance budgets are set before porting. No separate tooling project or additional approval ceremony is required. Historical oracle execution is confined to tests or an isolated checkout.

### P1 — Implement and qualify the Statelessness session

Specify the upstream contract above, implement the session using existing model/check/record primitives, and add generic regression fixtures. Run native Swift package and external-consumer qualification; pin the reviewed revision in Illiquid and record dependency resolution.

Exit: generic session tests execute successfully; package builds under the supported Swift toolchain; no claim of Illiquid runtime qualification yet.

### P2 — Port the production model

Create `IlliquidPlaybackModel`, port value types and rules by subsystem, and replace engine-local utilities. Use a temporary test-only comparison harness to execute identical concrete streams against the frozen old core and the new model. Compare every step, not just terminal snapshots or aggregate counts. Do not regenerate expected outputs from the new implementation to make differences disappear.

Exit: all P0 streams agree or each intentional correction has a reviewed discrepancy, new semantic version and old/new evidence. The P0 saved-data fixtures decode with preserved meaning, or an explicit versioned conversion is tested; moving Swift types alone is not evidence of compatibility. Check candidate execution overhead against the P0 budget. New model code has no dependency on the legacy core. A rename or wrapper fails this gate.

### P3 — Unify verification and replay

Rebase search transition materialization onto the production model. Preserve existing environment, canonicalization, progress and reduction contracts. Run every existing seed and negative control; require current graph/edge/failure/progress evidence at existing bounds. Extend scenarios for host admission and timer decisions now included in model state. Convert historical artifacts with explicit model/property/codec identities; never relabel old bytes as a new version.

Exit: live-model callback and verification callback are demonstrably shared, fresh-process replay works, target-preserving shrinking works, and all changed metrics have an explained cause. Deadline/memory/depth cutoffs remain incomplete coverage, not passes.

### P4 — Switch live playback

Change the driver to own the library session and migrate every production consumer to model types. Commit state before snapshot publication/effect execution; queue reentrant callbacks. Move acceptance decisions identified in the boundary ledger into the model. Run fake-runtime driver tests before real media qualification. If a temporary developer switch is used during this phase, give it a deletion gate; the release path cannot keep a second engine.

Exit: fake-runtime tests cover dispatch count/order, synchronous completion, source replacement, timers, failure and shutdown; native playback/UI/performance checks pass against the P0 baseline with exact process and bundle identity, the same hash-verified media/workloads, and the live-check overhead budget.

### P5 — Delete and prove retirement

Remove old product/target, implementation files, alternate runtime path, temporary selector and dual-engine harness. Retain frozen fixtures and provenance, not an executable fallback engine in shipped code. Port the existing core tests to model/session contracts rather than discarding their coverage. Extend architecture checks to forbid legacy imports and symbols in active sources and forbid media-framework dependencies in the model.

Exit: clean package builds, relevant full test suites execute, state-space profiles and native/live qualification rerun on the final deletion commit. A tracked-source scan and manifest inspection show no active legacy core dependency. Historical documentation/fixtures may name it in an explicit allowlist.

## Validation and release evidence

All builds, Swift test compilation and packaging that compiles Metal run through the shared Kyoto queue, preserving command/environment:

```sh
python3 /Volumes/seed1/Projects/kyoto/kyoto.py submit -- COMMAND ARGUMENTS
```

Inspect `show JOB_ID`, `logs JOB_ID` and `wait JOB_ID`. Serialize commands sharing `.build`. Follow [the macOS automation runbook](MACOS_AGENT_UI_AUTOMATION_RUNBOOK.md), including Kyoto preparation of new UI helpers, isolated benchmark bundle and exact process identity.

Required evidence layers:

1. **Generic library:** session contract tests and pinned external consumer compilation/execution.
2. **Deterministic application:** migrated core tests, per-step differential fixtures, all state-space families, replay/shrink, corruption and negative controls.
3. **Host/adapters:** fake-runtime scheduling tests and native failure, cancellation, authority and lifecycle tests; architecture guard.
4. **Actual player:** representative local/network media, audio-only and video, subtitles, seeks, track changes, replacement, sleep/wake, EOF and shutdown; retain failures and traces.
5. **Performance:** paired old/new runs on the same media, machine, build configuration and workload. Measure startup, command-to-effect latency, seek latency, stalls/dropped frames, CPU, physical footprint and long-session retained memory. Fix explicit acceptance thresholds in P0; do not invent improvement or accept a regression without measured evidence.

Receipts identify exact source/dependency/tool/media identities, command/environment, exit state, check coverage, cutoffs, findings and performance measurements. Queued, compiled, executed, and live UI-qualified are separate results. Existing verification receipts alone cannot authorize this release.

## Final acceptance and rollback

The retained `IlliquidPlaybackModel` is the application definition consumed by Statelessness, not a replacement home for the old standalone engine. Moving or renaming `PlaybackCore` into that module without transferring execution ownership fails acceptance.

Completion requires all of the following:

- Native Swift Statelessness owns production turn execution and committed state.
- Playback rules exist once as the application model; no live or verification call reaches `PlaybackCore.update` or `PlaybackModelRuntime`.
- `IlliquidPlaybackCore` is absent from active products, targets, imports and dependencies.
- The host and native adapters execute outputs and return inputs without a competing playback state machine; the boundary ledger has no unexplained policy owners.
- The completed verification migration remains functional on the new production model, with current evidence and explicit incomplete cases.
- Final-head deterministic, native, UI and performance gates have passed; temporary engines and switches are removed.

During development, rollback is a source/dependency revert to the frozen baseline. After release, rollback uses a known qualified application build and compatible persisted data. Do not retain the legacy engine as a runtime fallback: that would leave the requested migration incomplete.
