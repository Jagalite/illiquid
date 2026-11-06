# Full migration to Statelessness Swift

Status: implemented on branch `statelessness/migration-phase0` (2026-11-01).
Phase evidence, receipts and the discrepancy register are in
[StatelessnessMigration/STATUS.md](StatelessnessMigration/STATUS.md). This
document remains the plan of record. Its source references describe the
pre-migration code at `ea2ff568`.
Prepared 2026-10-30; reconciled with the active Statelessness native-parity
working tree on 2026-10-30.

Illiquid will adopt the native Swift `Statelessness.Model` as the common model
interface for playback verification and migrate its generic exploration,
graph analysis, reduction, recording, replay, and shrinking machinery into
Statelessness. Illiquid will retain playback state, production transitions,
environment models, property definitions, and application qualification policy.
The migration is complete when normal verification uses Statelessness throughout
and Illiquid's custom verification algorithms can be deleted.

The library is owned alongside Illiquid, so missing reusable capabilities should
be implemented upstream with independent contract tests. A permanent second
explorer hidden behind a Statelessness adapter would not meet this objective.

## Scope and architecture

`PlaybackCore.update(_:)` remains the production transition authority. A
Statelessness model calls the same production function that the player uses;
there must be no second implementation of playback behavior in verification.
This is full migration of the verification model and engine. It does not require
moving media I/O, renderer ownership, persistence, or the player lifecycle into
a model checker. Adding live recording to the player is a separate extension.

The final dependency direction is:

1. `IlliquidPlaybackCore` owns deterministic production state and transitions.
2. `IlliquidPlaybackStateSpace` owns playback-specific Statelessness models,
   codecs, abstractions, properties, and qualification configuration.
3. Native Swift Statelessness owns reusable verification algorithms.
4. `IlliquidStateSpaceExplorer` selects models and profiles, invokes the library,
   writes receipts, and applies Illiquid's CI acceptance rules.

Initially retain the existing product and target names to avoid unnecessary
consumer churn. Add the root Statelessness package's `Statelessness` product to
the verification target. Production playback targets need no new dependency.
Use an exact reviewed Git revision in committed package configuration; local
path overrides are development conveniences only. Resolve the dependency from
a clean checkout and retain `Package.resolved` according to repository policy.
The root package is pure Swift; `bindings/swift` and `bindings/swift-v2` are
different, Rust-backed packages and are not the migration destination.

## Source baseline

The planning snapshot has Illiquid HEAD
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72` and Statelessness HEAD
`7c20b6efde4995b123d782ab3fb7f2a5595a8850`. Both working trees contain local
changes. These revisions identify context, not clean build inputs or passing
qualification. Phase 0 must freeze actual file bytes and dependency identity.

Relevant Illiquid sources:

- [Production core](../Sources/IlliquidPlaybackCore/PlaybackCore.swift)
- [Current BFS and action application](../Sources/IlliquidPlaybackStateSpace/PlaybackStateSpaceExplorer.swift)
- [Model inventories and seeds](../Sources/IlliquidPlaybackStateSpace/PlaybackSearchModels.swift)
- [State, configuration, results and graph](../Sources/IlliquidPlaybackStateSpace/PlaybackSearchTypes.swift)
- [Canonical search identity](../Sources/IlliquidPlaybackStateSpace/PlaybackSearchCanonicalizer.swift)
- [Progress analysis](../Sources/IlliquidPlaybackStateSpace/PlaybackProgressAnalyzer.swift)
- [Reduction and diamond validation](../Sources/IlliquidPlaybackStateSpace/PlaybackPartialOrderReducer.swift)
- [Artifacts, replay, shrinking and runtime promotion](../Sources/IlliquidPlaybackStateSpace/PlaybackSearchArtifact.swift)
- [Baseline evaluator](../Sources/IlliquidPlaybackStateSpace/PlaybackSearchTrend.swift)
- [Executable](../Validation/IlliquidStateSpaceExplorer/main.swift),
  [runner](../Scripts/run-playback-state-space.sh), and
  [tests](../Tests/IlliquidPlaybackStateSpaceTests/PlaybackStateSpaceTests.swift)
- [Existing verification contract](PLAYBACK_STATE_SPACE_SEARCH.md)

Statelessness source references below are pinned repository links:
[package](https://github.com/Jagalite/statelessness/blob/7c20b6efde4995b123d782ab3fb7f2a5595a8850/Package.swift),
[Model.swift](https://github.com/Jagalite/statelessness/blob/7c20b6efde4995b123d782ab3fb7f2a5595a8850/swift/Sources/Statelessness/Model.swift),
[Explore.swift](https://github.com/Jagalite/statelessness/blob/7c20b6efde4995b123d782ab3fb7f2a5595a8850/swift/Sources/Statelessness/Explore.swift),
[Fuzz.swift](https://github.com/Jagalite/statelessness/blob/7c20b6efde4995b123d782ab3fb7f2a5595a8850/swift/Sources/Statelessness/Fuzz.swift),
[Shrink.swift](https://github.com/Jagalite/statelessness/blob/7c20b6efde4995b123d782ab3fb7f2a5595a8850/swift/Sources/Statelessness/Shrink.swift),
[Replay.swift](https://github.com/Jagalite/statelessness/blob/7c20b6efde4995b123d782ab3fb7f2a5595a8850/swift/Sources/Statelessness/Replay.swift), and
[Research.swift](https://github.com/Jagalite/statelessness/blob/7c20b6efde4995b123d782ab3fb7f2a5595a8850/swift/Sources/Statelessness/Research.swift).
They correspond to local source inspection, not a published release qualification.

## Current capability and final ownership

| Capability | Current native Swift support | Final responsibility |
| --- | --- | --- |
| Typed model and production transition adapter | `Model<State, Input, Output>` callbacks | Statelessness interface; Illiquid supplies playback semantics |
| Finite BFS | `enumerateStates`, equality, hashing, limits | Statelessness |
| Canonical identity | Custom equality and hash callbacks | Illiquid defines the quotient; Statelessness deduplicates safely |
| Transition checks | Checks run before duplicate elimination | Statelessness dispatch; Illiquid property definitions |
| Graph and frontier evidence | Observations precede admission; report has no full graph | Extend Statelessness with admitted graph and cutoff events |
| Multiple failures | BFS currently stops at first failed check | Extend Statelessness with explicit collection policy |
| Progress and cycles | No replacement for Illiquid's analyzer identified | Generic graph algorithms upstream; playback predicates stay local |
| Reduction | Research equivalence API explicitly enables no production pruning | Add qualified reusable reduction API upstream |
| Recording and replay | Native codecs and replay APIs exist | Statelessness execution; Illiquid codecs and provenance envelope |
| Causal shrinking | Native shrinker checks causality and preserves a target | Statelessness, with target and continuation semantics reconciled |
| Regression qualification | Application-specific counts, digests and model versions | Illiquid, consuming library reports |

## Reconciliation with active native parity work

The inspected checkout is `completion/native-parity-20261029`, still at the
planning HEAD above. Its active local work includes debugger service fixes,
TypeScript composition/network corrections, Go diagnostic queue and producer
operations, and a Swift `CampaignRuntime.swift` pthread entry-point correction.
These changes do not implement S1–S4 or change the current Swift BFS/shrink
contracts. Existing native-parity work does, however, narrow the migration's
new API requests and introduce an early package-build gate.

| Proposal | Reconciled scope |
| --- | --- |
| S1 Graph reporting | Still new. Reuse current BFS controls, limits and observations; add admission/expansion evidence and graph ownership. |
| S2 Failure collection | Still new. Also requires an explicit evidence contract for execution past an earlier failed check. |
| S3 Progress analysis | Still new. General liveness remains deferred in the library roadmap; playback predicates remain local. |
| S4 Reduction | Still new as production machinery. Build on N14's finite equivalence research and independent fixtures; do not duplicate that harness or treat it as pruning authorization. |
| S5 Replay and shrinking | Narrow to continued-failure witnesses, core API integration, and Illiquid codecs. Targeted terminal-failure selection, bounded recording, phase-aware evidence and checked results already exist. |
| S6 Qualification | Reuse the existing native-parity packaging and receipt discipline. First establish Swift 6 buildability for the exact package; qualify new capabilities separately. |

Prefer existing `TraceValueCodec`, `TraceRecords`, `TraceEnums`, and
`ModelCodecBinding` facilities when defining lossless playback codecs. Reuse
`checkInitial`/`checkTurn`, `recordAudit`, and `RuntimeEvidenceRecorder` where their
contracts fit instead of creating new generic checked-result or evidence APIs.
The current runtime recorder freezes at first failure, so its reuse does not
resolve continued-failure recording. Keep `StatelessDebug` optional: convenient
viewer functionality is not a reason to make playback verification depend on
debugger protocols or services.

The exact-width native count work already supplies `shrink64` and checked legacy
adapters, plus related generation/fuzz/campaign APIs. Follow those contracts for
new counters and reject narrowing overflow. Do not claim that all BFS fields
have migrated to UInt64: current `SearchConfig` uses `Int` for states/depth and
`UInt64` for transitions.

The active recovery status records Swift compiler failures in
`campaignSpawnRetained` and a later diagnostic pthread-signature failure; the
inspected local source includes a Darwin-specific entry-point correction.
That correction has no passing Swift 6 receipt established by this review.
`CampaignRuntime.swift` belongs to the same `Statelessness` target as BFS, so
avoiding campaign calls does not avoid compiling it. Phase 0 must consume a
qualified fix from the existing work or establish an upstream package split
with its own tests. Do not duplicate the active recovery effort or waive Swift 6.

Source anchors for this reconciliation:

- [Current recovery status](/Volumes/seed2/Projects/stateless/validation/native-parity/resume-20261029/STATUS.md)
  and [campaign runtime](/Volumes/seed2/Projects/stateless/swift/Sources/Statelessness/CampaignRuntime.swift)
  are live, uncommitted inputs. At review their SHA256 values were respectively
  `0f1762588dd958314ea2e36430fd2ccc9c8c28e19a5fa88636f8ebbfa8274c3d`
  and `0d08036667914076b05a2dc8c932c968b99ae05019150c4a0ef20d6eb603f442`.
- [Codec declarations](https://github.com/Jagalite/statelessness/blob/7c20b6efde4995b123d782ab3fb7f2a5595a8850/swift/Sources/Statelessness/DeriveCodec.swift),
  [checked results](https://github.com/Jagalite/statelessness/blob/7c20b6efde4995b123d782ab3fb7f2a5595a8850/swift/Sources/Statelessness/CheckedResults.swift),
  [runtime evidence recorder](https://github.com/Jagalite/statelessness/blob/7c20b6efde4995b123d782ab3fb7f2a5595a8850/swift/Sources/Statelessness/EvidenceRecorder.swift),
  and [targeted evidence viewer](https://github.com/Jagalite/statelessness/blob/7c20b6efde4995b123d782ab3fb7f2a5595a8850/swift/Sources/StatelessDebug/EvidenceViewer.swift)
  identify existing reusable APIs.
- [Native parity plan](https://github.com/Jagalite/statelessness/blob/7c20b6efde4995b123d782ab3fb7f2a5595a8850/docs/NATIVE-PARITY-PLAN.md)
  and [finite research contract](https://github.com/Jagalite/statelessness/blob/7c20b6efde4995b123d782ab3fb7f2a5595a8850/spec/research-equivalence-v1.md)
  supply the existing work boundaries. Historical lane passes do not qualify
  the combined current working tree.

## Model contract

Each of the six model families becomes a factory for
`Statelessness.Model<PlaybackSearchNode, SearchAction, PlaybackModelObservation>`.
`PlaybackModelObservation` is a proposed Illiquid type, not an existing API.

| Model callback | Mapping |
| --- | --- |
| `initialState` | Existing `makeSeed(profile:)` with model and configuration captured immutably |
| `inputs` | Existing ordered `enabledActions(for:configuration:)` as `InputIterator` |
| `step` | Extract current `apply` into a model adapter and call it once |
| `checkState` | Pure state properties, including checks of the initial seed |
| `checkTransition` | Read the observation from that step and emit production and model violations without rerunning it |
| `equalStates` | Compare complete `PlaybackSearchStateKey` values |
| `hashState` | Stable hash consistent with key equality; collisions still require full equality |
| Clone callbacks | Value copying after auditing nested state for mutable references |
| `codec` | Versioned lossless state and action codecs plus deterministic observation encoding |

The step observation carries the optional production transition and envelope,
ordered effects, gate disposition, invariant observations, fairness label, and
whether production was called. Command and accepted ingress actions call the
production core exactly once. Rejected ingress and environment-only actions keep
their existing zero-call behavior. Instrument these counts in adapter tests.

Represent accepted, rejected, and ignored outcomes through Statelessness's
disposition, while retaining the richer Illiquid disposition in the observation.
Do not collapse stale, duplicate, invalid, and post-termination reasons in traces.
Environment transitions and ingress rejection are explicit model steps, not
fabricated calls to production.

Separate three concepts:

- **Executable state:** sufficient to continue a real model run, including IDs,
  pending effects, environment, tombstones, ghost obligations, and sequence data.
- **Search identity:** the existing semantic quotient used for deduplication.
- **Portable evidence:** deterministic, versioned encoding for replay and review.

Canonical search identity is intentionally lossy and must not serve as the
decoder for executable state. Preserve concrete effect references for causal
replay. Cache keys only with well-defined invalidation and qualification.

Keep every seed, action class, required scenario, and bound from the current
inventory. The six families are seek, EOF/drain, recovery, track/subtitles,
stop/shutdown, and preroll/buffering. Freeze the actual inventory mechanically;
do not substitute six representative seeds for all supported seeds.

## Proposed Statelessness changes

The names in this section describe proposed contracts. They are not claims that
these APIs already exist. Implement additive opt-in behavior so existing native
and portable conformance profiles keep their established semantics.

### S1 Admitted graph and complete search reporting

Add graph capture or a structured graph sink with stable run-local node IDs,
predecessors, depth, and events for root admission, edge evaluation, successor
admission, duplicate edges, expansion completion, and incomplete expansion.
Carry input, disposition, checks, outputs, and user-defined edge annotations.
Distinguish an evaluated successor that failed admission from an admitted node.
Observers today run before deduplication and admission; reconstructing admission
by guessing from those callbacks is not an acceptable permanent contract.

Report evaluated transitions, admitted states, graph edges, duplicate edges,
frontier size, completed layers, and the precise stop reason. A node whose
expansion was interrupted must not appear closed. Keep failure evidence for
duplicate edges and for successors rejected by a state or memory cap. Provide
bounded retention or streaming options and account for graph storage separately
from `estimatedRetainedStateBytes`, which covers model states only.

Tests: diamond graph, self-loop, hash collisions, duplicate failing edge, state
cap on a new successor, edge cap midway through a node, cancellation, deadline,
zero depth, and a naturally exhausted graph. Assert event order and graph IDs.

### S2 Failure collection and explicit result semantics

Retain first-failure stopping as the existing default. Add an opt-in collection
policy with stable property identity, deterministic witnesses, and a declared
finding retention budget. Any retention truncation must be visible and must
not erase the fact that a check failed. Do not implement collection by changing
failed checks to passing checks in the adapter.

Preserve ordered state and transition checks, including multiple violations on
one edge. Continue exploring successors of failed checks only under the explicit
policy; model exceptions and partial checks remain incomplete/error outcomes.
The result must represent both findings and a later resource cutoff.

Align termination without losing information. Illiquid currently labels a
finished depth-limited run `completeWithinBounds`; native BFS distinguishes
`depth_bound` from `graph_exhausted`. The migrated report should distinguish
completed exploration through the declared depth from exhaustion of the whole
reachable finite graph. Depth-bound evidence is admissible only as bounded
coverage. State, edge, time, memory, cancellation, or reporting truncation cannot
silently become successful exhaustive coverage.

Tests: first and subsequent failures, multiple phases, duplicate-state failures,
failure plus cutoff, checker error after partial evidence, and deterministic
finding truncation. Note that Illiquid's configuration `failureLimit` bounds
modeled failure scenarios; it is not the new report retention limit.

### S3 Generic progress analysis

Add graph utilities for strongly connected components, reverse reachability,
rank comparisons, and closed-component detection. Applications supply terminal,
intentional-wait, external-wait, transaction, rank, and fair-edge predicates.
Illiquid retains those playback definitions; the graph traversal algorithms move
upstream. Use algorithms suitable for qualification-scale graphs, including an
explicit stack where recursion could exhaust the process stack.

Carry graph completeness into analysis. A depth frontier or partially expanded
node is unmeasured, not proof of deadlock or successful progress. Preserve the
current analyzer's classifications first, then review any stronger liveness
claim separately. Fair-path reachability and rank checks are not a general
proof that every scheduler execution eventually completes.

Tests: a settling transaction, intentional wait, declared external wait,
closed nonterminal cycle, unfair-only exit, fair rank decrease, depth cutoff,
and partial expansion. Use hand-authored graphs independent of playback.

### S4 Qualified reduction

Move generic action-equivalence grouping and enabled-action diamond validation
into an opt-in Statelessness reduction facility. Illiquid supplies eligible
action classes and observation projections. Preserve the existing narrow scope
first; do not introduce broad independence pruning during migration.

Require full canonical successor equality and preservation of relevant ordered
effects, dispositions, checks, and progress annotations. A digest match alone is
insufficient. Keep reduction decisions and rejected equivalences inspectable.
The current `Research.compareEquivalence` facility can supply bounded evidence,
but its results do not authorize production pruning by themselves.

Run reduced and unreduced searches at exhaustive small bounds and compare
reachable keys, property findings, progress results, and represented edge
equivalence classes. Raw edge counts need not match when actions are collapsed.
Retain an unreduced PR profile. Changes that strengthen the current comparison
signature must be reviewed separately from engine parity and versioned.

### S5 Targeted replay and shrinking

Use native recording, replay, and shrinking with Illiquid codecs. Preserve
original and minimized witnesses, replay counts, causal validity, selected
property and phase, and minimization history. Replay must compare outputs and
checks as well as states and dispositions; successful replay of a prefix must
not be reported as complete failure reproduction.

Current native shrinking chooses the first supplied violation and stops at the
first encountered failing step. A caller can already select a target by supplying
that violation; `EvidenceViewer.minimize` also selects a check and phase, verifies
the artifact, and delegates to the shrinker. Its selected failure must terminate
the artifact. Do not request a duplicate terminal-target selection facility.

The remaining gap is a witness whose selected failure occurs after an earlier
failed check. `Execution.validateRecording` rejects traces continuing after
failure, `record`/`recordAudit` stop there, and the runtime recorder freezes there.
Consequently S2 and S5 need a versioned continued-failure evidence contract and
matching record/replay/shrink behavior, not just a search-loop option. Reuse v2
phase/causal machinery where possible, but do not assume its version number
permits continued failures or silently change existing wire semantics.
Retain all earlier failures and specify which finding determines minimization
success; never suppress checks to force the target to appear. Add independent
cases for two failures on one turn versus failures on successive turns, selected
later targets, incompatible old readers, and incomplete checks after failure.

Initially reproduce current causal validity (referenced result effects must
exist). Review any stricter enabled-input rule as a semantic change: replay
validity and membership in a bounded search alphabet are different questions.
Keep both original and minimized witnesses even when minimization hits a budget.

### S6 Versioned qualification and packaging

Publish contracts and independent fixtures for S1–S5 in Statelessness. Declare
which APIs are Swift-only additions and which belong to a cross-language
profile. Do not imply Rust/native parity for a new extension without its own
qualification. Reuse existing native-parity qualification drivers and source
seals, extending their declared fixtures for the new capabilities rather than
creating a competing qualification system. Test the packaged Swift product from
an external consumer and pin that exact revision in Illiquid. Full qualification
of unrelated debugger features is not a prerequisite for this bounded migration
surface; buildability of all sources in the consumed Swift target is.

## Evidence and compatibility

Preserve the historical explorer as a frozen migration oracle, with source
hashes, tests, scripts, baselines, compiler identity, configuration, and actual
commands. Keep this snapshot independent of the new adapter. Both may call the
same pinned production core; do not make them share newly rewritten application
logic and then treat their agreement as independent evidence.

At small deterministic bounds compare full canonical key sets and normalized
edge multisets, not just aggregate counts or digests. Edge comparison includes
source and target keys, action identity, disposition, observations, and progress
label. Compare seed inventories, enabled actions, production-call counts,
rejected ingress counts, finding identities, witnesses, and progress classes.
Normalize node numbering and artifact container differences explicitly.

Use three categories for differences: a migration defect to fix; an intentional
report-format change with a lossless mapping; or a separately reviewed semantic
correction with a model/property version change and retained old evidence.
Do not relax checks, bounds, or baseline tolerances to obtain agreement.

Add independent negative controls for missing transitions, suppressed checks,
incorrect identity merging, stale ingress admission, omitted required effects,
false progress, incorrect reduction, and replay output corruption. Each control
must produce its intended failure or comparison mismatch. Existing injected
oracle tests remain useful but cannot alone prove the new engine catches a
production or adapter omission.

Preserve the existing PR trend baseline and its configured 25 percent count
tolerance for normal workload drift. Migration parity uses exact comparisons
where semantics agree; that tolerance is not permission to lose states or edges.
Retain the old baseline when introducing a versioned new artifact or model.

## Artifacts and historical replay

Use Statelessness traces inside an Illiquid qualification envelope containing
both repository revisions, relevant dirty-file hashes, resolved library version,
Swift and platform identity, model/property/codec versions, seed, all effective
bounds, reduction mode, selected failure policy, exit reason, and completeness.
Store the full inventory and configuration fingerprint with each run.

Provide a schema-versioned reader or converter for existing Illiquid artifacts.
Keep original bytes; conversion must report any fields it cannot preserve.
Historical conversion may retain a format reader, but not a second production
replay algorithm. Execute converted actions through the Statelessness model.
Where an old artifact requires old semantics, replay in its pinned historical
checkout rather than claiming current-source equivalence.

Keep runtime-promotion metadata and source effect contexts. Promotion is a
bridge to native qualification, not evidence that simulated playback exercised
actual decoders or renderers. Validate fresh-process replay, incompatible
versions, truncated/corrupted traces, reordered effects, and wrong property
targets. Resume records must match both source inputs and the entire effective
configuration; an old success marker is insufficient.

## Delivery phases

| Phase | Deliverables | Exit gate |
| --- | --- | --- |
| 0 Freeze contracts | Immutable historical source and evidence manifest; all seeds and profiles; executable baseline receipts; Swift 6 external-consumer build; discrepancy register | Baseline reproducible and consumed package buildable with exact inputs, or failures documented as blockers |
| 1 Upstream search foundation | S1 and S2 contracts, implementations, independent fixtures, packaged Swift tests; agree S5 continued-failure evidence contract | Admitted graph, continued failures, and cutoffs have tested semantics and a compatible witness design |
| 2 First model | Seek model adapter, clone audit, canonical equality, observations, versioned codecs | Every seek seed agrees at small bounds; negative controls and fresh-process replay pass |
| 3 All model families | EOF/drain, recovery, tracks/subtitles, shutdown, buffering; complete inventory | All seed/action/property inventories accounted; small-bound graph and failure parity passes |
| 4 Remaining generic machinery | S3 progress, S4 reduction, S5 replay/shrink; legacy artifact conversion | Independent graph fixtures, POR comparison, targeted failures, historical and new replay pass |
| 5 Qualification and default switch | S6 dependency pin, CLI/report compatibility, CI wiring, measured cost | All PR seeds qualify; declared nightly/qualification coverage has explicit receipts; no unexplained semantic differences |
| 6 Retirement | Delete custom algorithms and temporary dual-engine switch; update documentation and manifests | Sole active verification path uses Statelessness; historical evidence remains accessible |

Phases 1 and 4 require changes in Statelessness. Phases 0, 2, 3, 5, and 6 require
Illiquid integration. Pin each consumed upstream change before progressing.
Keep runtime bug fixes and new abstractions in separate reviewed changes so
engine comparisons have stable meaning. No calendar estimate is assigned before
Phase 0 establishes reproducible baseline cost and Phase 1 settles the APIs.

## Execution and acceptance

Run builds, test compilation, and packaging through Kyoto. For example, from the
appropriate repository directory, submit the intended command:

```sh
python3 /Volumes/seed1/Projects/kyoto/kyoto.py submit -- swift test --filter StatelessnessTests
python3 /Volumes/seed1/Projects/kyoto/kyoto.py submit -- swift test --filter PlaybackStateSpaceTests
python3 /Volumes/seed1/Projects/kyoto/kyoto.py submit -- ./Scripts/run-playback-state-space.sh
```

These are future execution templates, not completed receipts. Use the actual
target names and full required suites at each phase. Preserve profile and shard
environment on submission. Inspect `show JOB_ID`, `logs JOB_ID`, and
`wait JOB_ID`; report the effective command and executed outcome. Serialize jobs
sharing `.build`. The runner itself compiles, so submit the entire runner to the
queue and avoid nested submissions. Keep receipts outside temporary storage.

Qualification must include:

- Library contract tests and external Swift package consumption.
- Illiquid adapter tests and existing core/state-space regressions.
- All-seed deterministic parity and negative controls, including exact cap
  boundaries, repeated runs, shard union, and resume identity rejection.
- Replay and shrink tests for each family, plus multi-failure and causal cases.
- PR, nightly, and qualification runs at their recorded bounds. Any cap hit is
  incomplete evidence and requires explicit resolution before its coverage is
  claimed. A profile name alone does not establish coverage.
- Measured wall time, peak memory, graph storage, clone/canonicalization cost,
  and throughput on identical workloads and hardware. Establish cost budgets
  before cutover; do not change semantic acceptance to meet them.

Keep statuses distinct: source review, compiled, executed tests, bounded search,
native integration, live UI, and release qualification. This migration establishes
verification behavior; it does not replace native playback or UI qualification.

## Retirement and rollback

| Current Illiquid component | Final disposition |
| --- | --- |
| `PlaybackStateSpaceExplorer.run` | Delete traversal; optional compatibility facade delegates to Statelessness |
| `apply`, seed creation, action materialization | Retain as playback model callbacks, separated from traversal |
| `PlaybackSearchCanonicalizer` | Retain domain quotient and stable evidence projection |
| `PlaybackProgressAnalyzer` | Retain playback predicates; remove SCC and reachability algorithms |
| `PlaybackPartialOrderReducer` | Retain eligibility/projection policy; remove generic reduction and diamond loops |
| `PlaybackSearchMinimizer` and custom replay loop | Replace with Statelessness; keep only versioned format conversion |
| `PlaybackSearchArtifact` | Evolve into application provenance envelope around library evidence |
| `PlaybackSearchTrendEvaluator` | Retain application acceptance policy |
| CLI and runner | Retain invocation and sharding responsibilities; consume new reports |

Remove or reject unused configuration choices. For example, the current
configuration declares `iterativeDeepening`, while the inspected explorer uses
the same BFS loop without selecting that algorithm. Do not carry an unsupported
algorithm label into receipts as though it were implemented.

Until Phase 6, keep the frozen legacy path available for comparison and rollback.
During Phase 5, a release-blocking discrepancy reverts the verification default
and exact dependency pin while retaining new evidence for diagnosis. Rollback
must not rewrite historical receipts or silently reinterpret new traces with
old semantics. After retirement, historical worktrees and immutable fixtures
provide reproducibility without a permanent alternate engine in active code.

Completion requires all six families and all inventory seeds to use
`Statelessness.Model`; generic algorithms and normal trace execution to belong
to Statelessness; required evidence and negative controls to pass; and no hidden
fallback to the custom explorer. Domain-specific state and policies remaining
in Illiquid are part of the intended architecture.
