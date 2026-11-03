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
`0f0ebb5f` (Statelessness pinned at `43406954` on branch
`production/execution-session` of Jagalite/statelessness, proposed upstream
as [Jagalite/statelessness#20](https://github.com/Jagalite/statelessness/pull/20)),
after an independent gpt-6.1-sol review (see Review). This is not
release qualification: the locked release packager could not run on this
host (PD1).

## Architecture

| Component | Owner | Location |
| --- | --- | --- |
| Turn execution, committed state, sequence, checks, recording | Statelessness | `ExecutionSession` (production-execution-v1, pinned `43406954`) |
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
| P1 Session | Generic contract tests; package builds; pin | Statelessness `production/execution-session`: `ExecutionSession` and [production-execution-v1](https://github.com/Jagalite/statelessness/blob/43406954bb25dc4979f51d60d09860fc1f5435fa/spec/production-execution-v1.md). Contract tests with small standalone models, every behavior in certified and uncertified mode (06, 34); full upstream suite 750 tests, 0 failures (34; rerun on every upstream commit). Pinned at `43406954` |
| P2 Model | Every P0 step reproduced; no legacy dependency; not a rename or wrapper | `IlliquidPlaybackModel` depends on Statelessness and `IlliquidCore` only. All 35,136 frozen legacy steps reproduced through a persistent session and through the bare step (08; rerun in every later full suite) |
| P3 Verification | Search runs on the production model; golden evidence unchanged | State space calls `PlaybackProductionModel.step`; all 40 seeds match the verification golden edge digests, progress and reduction; artifacts replay and shrink; seeds equal the frozen starts (09) |
| P4 Live switch | Driver owns the session; fake-runtime and live checks against P0 | Driver submits through `PlaybackSessionHost`; player, native and coordinator tests pass serially (10–12, 17, 37). Every oracle event stream driven through the host matches the legacy runtime's envelope sequence, virtual-time and pending-effect policy step for step (`SessionHostEquivalenceTests`, 36). Live UI and paired performance below |
| P5 Retirement | Legacy gone; guard enforces it; final-head gates | `Sources/IlliquidPlaybackCore`, its product, target and tests removed; core tests ported to the model and session. `IlliquidArchitectureCheck` forbids legacy symbols and checks ownership structurally: live targets may not call the model step, build a session or store `PlaybackDomainState`; the model module may not store it; the host must execute through its session; the production model must be a Statelessness model; missing files fail. A mutation probe adding a stored-state shadow to a live target is rejected (36). The guard catches these patterns; ownership itself was also confirmed by review. Final-head runs: 37–39 |

## Final-head evidence (`0f0ebb5f`)

Build-side gates ran as one sequential Kyoto job (37); live checks ran
afterwards on the quiet host. An earlier full set on `c450b683` (25–28, 31)
gave the same results before the review fixes.

| Check | Result | Receipt |
| --- | --- | --- |
| Architecture check | Passed | 37 |
| Full suite, serial, native fixtures required | 1,820 tests: all pass except `hardwarePreservesPixelsTimingAndMetadataIncludingSeek` (VP9 10-bit) and `planarEOFDrainAndTeardownAreBounded`, which fail identically on the P0 baseline (PD11) | 37, 23 |
| Long-duration AV sync and memory gate (60 s, 3 fixtures) | Passed | 37 |
| Renderer recovery script (production model, no native SDK) | 18 tests passed | 37 |
| AddressSanitizer and ThreadSanitizer playback stress (HDR10 P010, 12 reopens) | Passed | 37 |
| State space, PR profile | Exit 0: 40/40 finished, 0 findings, 0 trend violations against the PR baseline | 37 |
| State space, nightly profile | Exit 2: 0 findings, 0 trend violations; `seek-in-flight`, `recovery-in-flight` and `preroll-buffering/playing-av` reach the deadline, as recorded for the legacy explorer (verification migration D23) | 37 |
| State space, qualification profile | Exit 2: 0 findings, 0 trend violations; the same five deadline seeds as the verification migration record | 37 |
| Live UI, hook-driven playback (isolated benchmark bundle, validated preference isolation) | 22/22 steps: load, pause, play with advancing position, exact seeks 2 s → 7 s → 2 s. A first attempt timed out at launch before the app became ready (kept as receipt); the immediate retry passed | 39 |
| Live paired performance cohort vs P0 baseline (6 balanced repeats, output case) | Passed the reviewed policy on every metric; zero dropped and zero corrupted frames in both cohorts | 38 |
| Deterministic turn cost (release) | Legacy 1.01 µs; model step 1.36 µs; session 3.88 µs per turn (PD12) | 03, 37 |

## Review

An independent gpt-6.1-sol review of the Illiquid commits and the upstream
session found no playback behavior difference (rule bodies match the legacy
bodies after mechanical renaming; registration precedes invariant checking;
invariant failure keeps emitted effects) and confirmed that execution and
committed state are owned by the session. Its findings and dispositions:

| Finding | Disposition |
| --- | --- |
| Uncertified sessions checked a reference input after the step had mutated it | Fixed upstream: both modes give checks a pristine input copy; tested in both modes |
| Session adopted step results without detaching them from references the step keeps | Fixed upstream: the returned transition is detached with the clone contract before use; tested in both modes |
| `snapshot()` bypassed the reentrancy guard | Fixed upstream; snapshot reentrancy from steps and clone callbacks tested |
| Harness repair made default profiling commands fail | Defaults now cover only seedable cases; unseedable cases fail up front with the reason (PD10) |
| Architecture guard weaker than claimed | Ownership checks and a mutation probe added; P5 wording describes what the guard proves |
| Oracle bypassed the host | `SessionHostEquivalenceTests` drives every oracle stream through the host against the legacy host policy |
| Missing contract coverage (output-clone faults, recorder capacity, mode matrix) | Added upstream |

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
  increase; no corrupted frames. Cohort medians baseline → candidate:
  steady CPU 9.68 → 9.99 %, hover 17.27 → 17.65 %, resize
  15.96 → 15.88 % (`c450b683`, 28); on the final head (38): steady
  9.09 → 8.96 %, hover 16.51 → 17.04 %, resize 14.93 → 15.16 %; footprint
  155.1 → 152.3 / 170.2 → 171.8 / 175.2 → 172.4 MiB; displayed seek
  78.7 → 83.0 ms (max 135.5 → 115.4); quit 380 → 398 ms; launch 830 → 444 ms.
  Dropped and corrupted frames 0 in every run.
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
| PD10 | defect (harness, fixed) | The lifecycle/output/responsiveness probes passed a benchmark control session without the isolated preference suite the app requires since the preference isolation contract, so every benchmark launch was refused, baseline included. | Probes now pass a fresh suite, receipt and scalar JSON seed. JSON cannot carry Data-valued seeds, so cases that seed history or source lists (lifecycle `history10k`/`history100k`/`sources1000`, responsiveness and suite navigation) cannot run under isolation: defaults exclude them and explicit requests fail up front with that reason. Output, empty-launch, preview and soak cases run. Restoring the excluded cases needs an app-side way to seed Data values. None of them involves the playback model. |
| PD11 | pre-existing | With native fixtures required, `hardwarePreservesPixelsTimingAndMetadataIncludingSeek` (VP9 10-bit: 10 frames, expected ≥ 12) and `planarEOFDrainAndTeardownAreBounded` fail; the differential smoke cannot start the mpv oracle. | Identical on the P0 baseline checkout (23, 24): decoder/fixture and host mpv environment, not the playback model. |
| PD12 | measured regression (accepted on live evidence) | Deterministic per-turn cost on the oracle workload (release): legacy core 1.01 µs; model step 1.36 µs (output array and Statelessness `Transition`); live session 3.88 µs (clone and check callbacks through Statelessness's generic closure-based `Model`, which copies the state value through reabstraction thunks; the review's ownership fixes add one detaching clone). Upstream reductions brought the session from 5.5 µs to 3.55 µs before those fixes (14–16, 18, 37). This is not measured against a pre-established turn-cost budget; acceptance rests on the live cohort. | About 2.5 µs per playback event; the live paired cohort shows no CPU, latency or frame regression. Further reduction needs a Statelessness API change (for example specialized or inlinable session paths). |
| PD13 | evidence limit | A first batch of qualification jobs ran concurrently in Kyoto (19–22), so their deadlines and timings are not valid evidence (the PR profile missed its 60 s deadline on `recovery-in-flight` under that contention). | Superseded by the strictly serial final runs (25, 26), where the PR profile passes. |
| PD14 | evidence limit | Launch time is bimodal (about 0.4 s or about 1.1 s) depending on which app launches second in a repeat; an unbalanced five-repeat cohort (30) failed `launch_ms` for that reason. | Balanced six-repeat cohorts (28, 29) pass; the bimodality affects both apps. |
| PD15 | open (owner decision) | The pinned Statelessness revision is on the pushed branch `production/execution-session`, proposed as [Jagalite/statelessness#20](https://github.com/Jagalite/statelessness/pull/20), not yet merged to Statelessness `main`. | Merging is the owner's decision; the pin needs no change if the commits are merged as they are. |
