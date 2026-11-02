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
below with its receipt. Final-head evidence was produced on commit
`c450b683` (Statelessness pinned at `a181e3c0` on branch
`production/execution-session` of Jagalite/statelessness). This is not
release qualification: the locked release packager could not run on this
host (PD1).

## Architecture

| Component | Owner | Location |
| --- | --- | --- |
| Turn execution, committed state, sequence, checks, recording | Statelessness | `ExecutionSession` (production-execution-v1, pinned `a181e3c0`) |
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

Receipts are in [receipts/](receipts) (Kyoto job record and filtered log per
job, numbered as below).

| Phase | Gate | Evidence |
| --- | --- | --- |
| P0 Freeze | Frozen oracle, boundary ledger, budgets agreed | Commit `a3c2013c`. Legacy core manifest [legacy-core-44722ec5.json](legacy-core-44722ec5.json). Differential oracle `production-migration-oracle-v1.json`: 366 streams × 96 steps from 42 start states (fresh, exhausted allocators, all 40 reachable search seeds) recorded from the legacy core (01) and re-verified at that commit (02). Legacy turn cost (03). Fixed native media set with hashed manifest (04, [native-fixture-manifest.json](receipts/native-fixture-manifest.json)) and a 60 s 1080p H.264/AAC performance fixture ([perf-fixture.sha256](receipts/perf-fixture.sha256)). Baseline benchmark bundle from `44722ec5` (05). Ledger, persisted-data inventory and budgets below |
| P1 Session | Generic contract tests; package builds; pin | Statelessness `production/execution-session`: `ExecutionSession` and [production-execution-v1](https://github.com/Jagalite/statelessness/blob/a181e3c0f2f644f482cbeb37016ed1d54eaf86f9/spec/production-execution-v1.md). 13 contract tests with toy models (06); full upstream suite 745 tests, 0 failures (07, and rerun on every later upstream commit). Pinned at `a181e3c0` |
| P2 Model | Every P0 step reproduced; no legacy dependency; not a rename or wrapper | `IlliquidPlaybackModel` depends on Statelessness and `IlliquidCore` only. All 35,136 frozen legacy steps reproduced through a persistent session and through the bare step (08; rerun in every later full suite) |
| P3 Verification | Search runs on the production model; golden evidence unchanged | State space calls `PlaybackProductionModel.step`; all 40 seeds match the verification golden edge digests, progress and reduction; artifacts replay and shrink; seeds equal the frozen starts (09) |
| P4 Live switch | Driver owns the session; fake-runtime and live checks against P0 | Driver submits through `PlaybackSessionHost`; player, native and coordinator tests pass serially (10–12, 17, 25). Live UI and paired performance below |
| P5 Retirement | Legacy gone; guard enforces it; final-head gates | `Sources/IlliquidPlaybackCore`, its product, target and tests removed; core tests ported to the model and session. `IlliquidArchitectureCheck` forbids legacy symbols and requires the model to be defined on Statelessness (13, 25). Final-head runs: 25–33 |

## Final-head evidence (`c450b683`)

| Check | Result | Receipt |
| --- | --- | --- |
| Architecture check | Passed | 25 |
| Full suite, serial, native fixtures required | 1,818 tests: all pass except `hardwarePreservesPixelsTimingAndMetadataIncludingSeek` (VP9 10-bit) and `planarEOFDrainAndTeardownAreBounded`, which fail identically on the P0 baseline (PD11) | 25, 23 |
| Long-duration AV sync and memory gate (60 s, 3 fixtures) | Passed | 25 |
| Renderer recovery script (production model, no native SDK) | 18 tests passed | 25 |
| AddressSanitizer and ThreadSanitizer playback stress (HDR10 P010, 12 reopens) | Passed | 25 |
| State space, PR profile | Exit 0: 40/40 finished, 0 findings, 0 trend violations against the PR baseline | 26 |
| State space, nightly profile | Exit 2: 0 findings, 0 trend violations; `seek-in-flight`, `recovery-in-flight` and `preroll-buffering/playing-av` reach the deadline, as recorded for the legacy explorer (verification migration D23) | 26 |
| State space, qualification profile | Exit 2: 0 findings, 0 trend violations, 0 undeclared noncommuting diamonds; the same five deadline seeds as the verification migration record | 26 |
| Live UI, hook-driven playback (isolated benchmark bundle, validated preference isolation) | 22/22 steps: load, pause, play with advancing position, exact seeks 2 s → 7 s → 2 s | 31 |
| Live paired performance cohort vs P0 baseline (6 balanced repeats, output case) | Passed the reviewed policy on every metric; zero dropped and zero corrupted frames in both cohorts | 28 |
| Deterministic turn cost (release) | Legacy 1.01 µs; model step 1.35 µs; session 3.55 µs per turn (PD12) | 03, 18 |

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

- **Live player (acceptance):** the reviewed paired-cohort policy of
  `Scripts/profile-performance-suite.py`: medians ≤ max(1.15 × baseline,
  baseline + 2 CPU points / 16 MiB / 25 ms); maximum dropped frames cannot
  increase; no corrupted frames. Final cohort (28), medians baseline →
  candidate: steady CPU 9.68 → 9.99 %, hover 17.27 → 17.65 %, resize
  15.96 → 15.88 %; footprint 157.5 → 152.6 / 174.9 → 169.1 / 169.5 → 171.4 MiB;
  displayed seek 85.6 → 91.3 ms (max 131.8 → 133.7); quit 382 → 317 ms;
  launch 1,136 → 916 ms. Dropped and corrupted frames 0 in every run.
- **Deterministic turn cost (recorded, not an acceptance gate):** see PD12.
- **Long sessions:** the live session keeps no step history; completed-effect
  identity history is compacted as before; the 60 s AV-sync and memory gate
  passes.

## Discrepancy register

| ID | Category | Finding | Disposition |
| --- | --- | --- | --- |
| PD1 | environment | Host Homebrew moved `opt/x265` to 4.3 (`libx265.217`), and glib, harfbuzz, openssl@3 and pcre2 no longer match the reviewed native lock. | A `libx265.216.dylib` compatibility link to the installed 4.2 keg was added inside the 4.3 keg (additive; nothing replaced; remove with `rm`). Locked release packaging (`build-illiquid-app.sh`) needs the reviewed kegs, which this host lacks; the CI SDK installer would re-point shared `opt` links, so it was not run. Baseline and candidate benchmark bundles are both built with the runbook's local packager `build-app.sh` (like for like). Release packaging and notarization remain to be run on CI. |
| PD2 | semantic (host) | Envelope sequence and virtual-time policy moved from `PlaybackModelRuntime` to `PlaybackSessionHost`, unchanged (start at the state's virtual time, +1 tick per input, saturating). | Oracle and ported tests. |
| PD3 | format | Replay documents and the ad hoc deletion shrinker are replaced by Statelessness traces, replay and `shrinkContinued`. | Ported tests; no production consumer. |
| PD4 | format | `PlaybackCoreState` → `PlaybackDomainState` and other module-level renames. | Codable keys unchanged; golden and oracle digests unchanged. |
| PD5 | semantic (new) | Statelessness classification of dispositions: accepted; duplicate, stale and invalid → rejected; ignored after termination → ignored. The playback disposition is kept verbatim in the output. | `PlaybackProductionModel.disposition`. |
| PD6 | semantic (new path) | A session fault (sequence exhaustion after 2^64 turns, or a thrown clone/check, impossible for these value types) is reported by the host as `invalid(sessionFault)` with no effects and nothing committed. | Covered by upstream contract tests; never reached in Illiquid tests. |
| PD7 | test | The seeded command generator now draws from Statelessness `Rng`; sequences differ from the legacy generator. | Test-only; the property checked (determinism, no violations) is unchanged. |
| PD8 | evidence limit | Under full parallel `swift test` load, a stable set of timing-sensitive tests (thumbnail deadlines, filesystem watcher, scanner, click interval, coordinator preparation, subtitle probe) fail; they pass serially both here and on the baseline checkout. | Pre-existing; tracked separately. |
| PD9 | environment | Synthetic key events from the agent UI helper fail on this host ("Accessibility messaging could not complete") for both the baseline and the candidate, at the first key step of `playback-shortcuts`; the six hook and state steps before it pass on both (32, 33). | A hook-driven variant (31) keeps every assertion and drives play, pause and exact seeks through the benchmark control hook into the real controller; it passes 22/22 on baseline and candidate. Real-key delivery is not qualified here. |
| PD10 | defect (harness, fixed) | The lifecycle/output probes passed a benchmark control session without the isolated preference suite the app requires since the preference isolation contract, so every benchmark launch was refused, baseline included. | Probes now pass a fresh suite, receipt and scalar JSON seed. JSON cannot carry Data-valued seeds, so the navigation case (100,000 seeded source items) cannot run; the suite gained `--skip-navigation`. Sidebar navigation does not involve the playback model. |
| PD11 | pre-existing | With native fixtures required, `hardwarePreservesPixelsTimingAndMetadataIncludingSeek` (VP9 10-bit: 10 frames, expected ≥ 12) and `planarEOFDrainAndTeardownAreBounded` fail; the differential smoke cannot start the mpv oracle. | Identical on the P0 baseline checkout (23, 24): decoder/fixture and host mpv environment, not the playback model. |
| PD12 | measured regression (accepted on live evidence) | Deterministic per-turn cost on the oracle workload (release): legacy core 1.01 µs; model step 1.35 µs (output array and Statelessness `Transition`); live session 3.55 µs (clone and check callbacks through Statelessness's generic closure-based `Model`, which copies the state value through reabstraction thunks). Two upstream reductions brought the session from 5.5 µs to 3.55 µs (14–16, 18). | About 2.5 µs per playback event; the live paired cohort shows no CPU, latency or frame regression. Further reduction needs a Statelessness API change (for example specialized or inlinable session paths). |
| PD13 | evidence limit | A first batch of qualification jobs ran concurrently in Kyoto (19–22), so their deadlines and timings are not valid evidence (the PR profile missed its 60 s deadline on `recovery-in-flight` under that contention). | Superseded by the strictly serial final runs (25, 26), where the PR profile passes. |
| PD14 | evidence limit | Launch time is bimodal (about 0.4 s or about 1.1 s) depending on which app launches second in a repeat; an unbalanced five-repeat cohort (30) failed `launch_ms` for that reason. | Balanced six-repeat cohorts (28, 29) pass; the bimodality affects both apps. |
| PD15 | open (upstream) | The pinned Statelessness revision is on the pushed branch `production/execution-session`, not yet merged to Statelessness `main`. | Merge upstream through review; the pin needs no change if the commit is merged as is. |
