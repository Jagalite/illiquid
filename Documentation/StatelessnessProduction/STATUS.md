# Statelessness production migration status

Status: **implemented on branch `statelessness/production-migration`**,
2026-11-02, against [the production migration plan](../STATELESSNESS_PRODUCTION_MIGRATION.md).
The legacy `PlaybackCore`, `PlaybackModelRuntime` and the
`IlliquidPlaybackCore` product/target are deleted. Playback rules exist once,
as the native Statelessness model in `IlliquidPlaybackModel`; the live player
submits every input to a Statelessness `ExecutionSession`, and verification
explores the same `step` callback.

Statuses stay distinct: compiled, executed tests, bounded search, native
integration, live UI and release qualification. Evidence for each is listed
below with its receipt.

## Architecture

| Component | Owner | Location |
| --- | --- | --- |
| Turn execution, committed state, sequence, checks, recording | Statelessness | `ExecutionSession` (production-execution-v1, pinned `20fc035e`) |
| Playback state, events, effects, rules, invariants, UI projection | Illiquid model | `Sources/IlliquidPlaybackModel` (`PlaybackProductionModel.step`, `PlaybackRules.swift`, `*Machine.swift`) |
| Codec (canonical JSON) | Illiquid model | `PlaybackProductionCodec.swift`, `CanonicalJSON.swift` |
| Host input contract (envelope sequence and virtual time, dispatched-effect list) | Illiquid model | `PlaybackSessionHost.swift` |
| Live host (main actor, snapshots, effect hand-off, timers, I/O mapping) | Illiquid player | `PlaybackRuntimeDriver.swift` |
| Effect execution, native fences, resources | Native adapters | `IlliquidNativePlayback` (unchanged) |
| Verification (environments, search actions, quotient, policies) | Illiquid state space | `IlliquidPlaybackStateSpace`, now calling `PlaybackProductionModel.step` |

Dependency direction: Player → Playback / NativePlayback / PlaybackModel;
Playback and NativePlayback → PlaybackModel; StateSpace → PlaybackModel +
Statelessness; PlaybackModel → Statelessness + IlliquidCore value types.
Statelessness imports nothing from Illiquid.

The model step is a pure function of `(PlaybackDomainState, PlaybackEventEnvelope)`.
It copies the committed value, applies the rules (extensions on the state
value: no engine object, no retained mutable owner), checks invariants on the
candidate together with the emitted effects, and returns
`Transition(state:outputs:[PlaybackTransition], disposition:)`. Invariant
failure still moves the lifecycle to `invariantFailed` inside the same turn,
as before; the model's transition check reports each violation as a failed
Statelessness check without re-running the step. The session commits that
turn (a failed check batch is a committed turn, not a rollback).

## Phase gates

| Phase | Gate | Evidence |
| --- | --- | --- |
| P0 Freeze | Frozen oracle, boundary ledger, budgets agreed | Commit `a3c2013c`. Legacy core manifest [legacy-core-44722ec5.json](legacy-core-44722ec5.json). Differential oracle `production-migration-oracle-v1.json`: 366 streams × 96 steps from 42 start states (fresh, exhausted allocators, all 40 reachable search seeds), recorded from the legacy core (Kyoto `540af2f5…`) and re-verified from that commit (`a6c984b1…`). Baseline benchmark bundle built from `44722ec5` (`4aacadc6…`). Fixed media set generated with its hashed manifest (`d53fe7ef…`). Ledger, persisted-data inventory and budgets below |
| P1 Session | Generic contract tests; package builds; pin | Statelessness `production/execution-session` `20fc035e`: `ExecutionSession` + spec `production-execution-v1.md`; 13 contract tests with toy models (`337446e4…`); full upstream suite 745 tests, 0 failures (`813c4b94…`); pinned in `Package.swift` |
| P2 Model | Every P0 step reproduced; no legacy dependency; not a rename or wrapper | `IlliquidPlaybackModel` has no dependency on the legacy core. All 35,136 frozen steps reproduced through a persistent session and through the bare step (`9031ce44…`) |
| P3 Verification | Search runs on the production model; golden evidence unchanged | State space calls `PlaybackProductionModel.step`; all 40 seeds still match the verification golden edge digests, progress and reduction; artifacts replay and shrink; seeds equal the frozen starts (59 tests, `b22aa6f2…`) |
| P4 Live switch | Driver owns the session; fake-runtime and live checks against P0 | Driver submits through `PlaybackSessionHost`; player, native and coordinator tests pass; live and performance evidence below |
| P5 Retirement | Legacy target, files and runtime gone; guard enforces it | `Sources/IlliquidPlaybackCore` and its product, target and tests removed; core tests ported to the model and session; `IlliquidArchitectureCheck` forbids legacy symbols and requires the model to be defined on Statelessness |

## Boundary ledger

Policies outside the model, with the reason each stays and its test.

| Policy | Owner | Reason | Test |
| --- | --- | --- | --- |
| Runtime identity gate (`PlaybackRuntimeEventGate`) | Host (`IlliquidPlayback`) | Transport normalization of native callbacks by runtime identity; the model still validates effect authority and context, so a late callback that passes the gate is rejected by the model as stale. Verification models gate rejection as an explicit non-production step | `RuntimeContractTests`, state-space `ingressRejected` controls |
| Pending load request and URL mapping | Driver | URLs and file handles are opaque resources outside deterministic state; activation reads committed state only | `PlaybackCoordinatorTests` |
| Relative-seek dispatch coalescing (40 ms) | Driver | Scheduling of an already accepted effect. Which seek wins is decided by the model (each seek issues a new pipeline effect and supersedes the old by generation). For an effect never handed to an executor the driver reports `cancelled` when the model's authority rule says it is no longer current | `RelativeSeekEffectLifetimeTests` |
| Checkpoint persistence, playlist advance | Driver | Executors for effects; results return as inputs | `PlaybackCoordinatorTests` |
| Shutdown waiters | Driver | Continuations, not playback state | `PlaybackCoordinatorTests` |
| Native session/generation fences, decoder and device scheduling | Native adapters | Resource ownership of opaque native objects | `RuntimeAuthorityFenceTests`, `NativeOperationWorkLifetimeTests` |
| Envelope sequence and virtual time | `PlaybackSessionHost` | Host input contract: monotonic logical time is supplied as input, never read from a clock by the model | `PlaybackSessionHostTests`, oracle |

No correctness decision about lifecycle or authority remains in the host
outside the model: the driver's checks call `PlaybackDomainState.authorityIsCurrent`
on committed state.

## Persisted data inventory

No production persistence stores playback model state. Serialized forms:

| Data | Codec | Change |
| --- | --- | --- |
| State-space codec `PlaybackModelCodec` v1 (search state including the domain state) | Canonical JSON | None: renaming `PlaybackCoreState` to `PlaybackDomainState` changes no keys or bytes; golden digests are unchanged |
| Verification artifacts and fixtures | Canonical JSON + Statelessness traces | None |
| Production model codec `PlaybackProductionCodec` v1 | Canonical JSON | New, for Statelessness recording and replay |
| `PlaybackReplayDocument` (test-only) | JSON | Removed; replaced by Statelessness audit traces |

## Oracle coverage and findings

Recorded from the legacy core and reproduced by the model:

- Events: every `PlaybackEvent` case. Dispositions: all five.
- Effects emitted: 22 kinds, including recovery (`recreateVideoDecoderInSoftware`,
  `resumeVideoDecoderAfterTransientFailure`, presentation/audio flushes, track
  disables). `seek`, `flushDecoder`, `rebuildPresentationGraph` and
  `rebuildAudioPresentation` are reachable only through longer recovery
  ladders than the streams exercise and remain covered by the ported recovery
  regression tests. `cancelInputRead`, `installPresentationFence`,
  `releaseLease` and `mirrorDiagnostic` are never emitted by the rules.
- Lifecycles: running, shuttingDown, terminated, invariantFailed.
- **Finding (preserved, not fixed):** generated input streams reach invariant
  violations in the legacy core: `playingRequiresCurrentPreroll` (168 steps)
  and `playingRequiresPlayingPhase` (4). They are frozen behavior and the model
  reproduces them. Whether those input orders are reachable from the native
  runtime is a separate reviewed behavior question. Statelessness
  `shrinkContinued` minimizes such a stream (`invariantFailureIsShrunkByStatelessness`).

## Cost budgets

- Deterministic turn cost (release, same host, oracle workloads): legacy core
  1,008 ns/turn median (`e08aa282…`). Budget for the session path:
  ≤ max(1.15 × legacy, legacy + 1 µs).
- Live player: the reviewed paired-cohort policy of
  `Scripts/profile-performance-suite.py`: medians ≤ max(1.15 × baseline,
  baseline + 2 CPU points / 16 MiB / 25 ms); maximum dropped frames cannot
  increase; no corrupted frames.
- Long sessions: the session keeps no step history; completed-effect identity
  history is compacted as before.

## Discrepancy register

| ID | Category | Finding | Disposition |
| --- | --- | --- | --- |
| PD1 | environment | Host Homebrew moved `opt/x265` to 4.3 (`libx265.217`), and glib, harfbuzz, openssl@3 and pcre2 no longer match the reviewed native lock. | A `libx265.216.dylib` compatibility link to the installed 4.2 keg was added inside the 4.3 keg (additive; nothing replaced). Locked release packaging (`build-illiquid-app.sh`) needs the reviewed kegs, which this host lacks; baseline and candidate benchmark bundles are both built with the runbook's local packager `build-app.sh`, so the comparison is like for like. Not release qualification. |
| PD2 | semantic (host) | Envelope sequence and virtual-time policy moved from `PlaybackModelRuntime` to `PlaybackSessionHost`, unchanged (start at the state's virtual time, +1 tick per input, saturating). | Oracle and ported tests. |
| PD3 | format | Replay documents and the ad hoc deletion shrinker are replaced by Statelessness traces, replay and `shrinkContinued`. | Ported tests; no production consumer. |
| PD4 | format | `PlaybackCoreState` → `PlaybackDomainState` and other module-level renames. | Codable keys unchanged; golden and oracle digests unchanged. |
| PD5 | semantic (new) | Statelessness classification of dispositions: accepted; duplicate, stale and invalid → rejected; ignored after termination → ignored. The playback disposition is kept verbatim in the output. | `PlaybackProductionModel.disposition`. |
| PD6 | semantic (new path) | A session fault (sequence exhaustion after 2^64 turns, or a thrown clone/check, impossible for these value types) is reported by the host as `invalid(sessionFault)` with no effects and nothing committed. | Covered by upstream contract tests; never reached in Illiquid tests. |
| PD7 | test | The seeded command generator now draws from Statelessness `Rng`; sequences differ from the legacy generator. | Test-only; the property checked (determinism, no violations) is unchanged. |
| PD8 | evidence limit | Under full parallel `swift test` load, a stable set of timing-sensitive tests (thumbnail deadlines, filesystem watcher, scanner, click interval, coordinator preparation, subtitle probe) fail; they pass serially both here and on the baseline checkout. | Pre-existing; tracked separately. |
