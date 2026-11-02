# Playback bounded state-space search

Illiquid verifies the production playback model (`PlaybackProductionModel.step`,
the same callback the live player's Statelessness session executes) with
the native Swift [Statelessness](https://github.com/Jagalite/statelessness)
library, pinned to an exact revision in `Package.swift`. Illiquid owns the
playback models, transition adapter, search identity, properties, progress
and reduction policies, and acceptance rules. Statelessness owns graph search,
failure collection, progress graph algorithms, reduction, recording, replay
and shrinking. The search exhausts finite policy schedules; it is not a media
simulator. The migration from the earlier custom explorer is recorded in
[STATELESSNESS_SWIFT_MIGRATION.md](STATELESSNESS_SWIFT_MIGRATION.md) and
[StatelessnessMigration/STATUS.md](StatelessnessMigration/STATUS.md).

## Scope and evidence boundary

Six independent models cover seek, EOF/drain, recovery, track/subtitles,
stop/shutdown, and preroll/buffering. Each run uses a reachable production seed
and a model-specific finite action alphabet. The model never stores files,
packets, frames, sample buffers, media objects, wall-clock time, or unbounded
identifiers.

Commands, current-authority runtime facts, and identified effect results call
the production core exactly once. Previous or unrelated raw callbacks run
through the shared ingress relation and are rejected before the core. Executor
prerequisite and abstract queue/resource actions update only the bounded
environment ledger; they cannot change production state.

Aggregate seek, recovery, and replacement success is enabled only after its
finite prerequisite set is complete. Aggregate zero-drain EOF remains a
separate production-contract profile. These bits test policy around an
acknowledgement; native tests and physical qualification remain responsible for
proving the actual mechanism.

## Search and state identity

`PlaybackStatelessnessModels.make` builds one `Statelessness.Model` per
family and seed. Statelessness `exploreGraph` performs layered breadth-first
search with stable input ordering, an admitted graph with predecessors, and
hard state/transition/depth/time/graph-byte caps. Failures are collected
without stopping, and failing successors are still expanded. Coverage is
reported as `exhaustive`, `bounded` (depth), or `incomplete(reason)`. Only the
first two are finished searches.
`PlaybackSearchStateKey` structurally alpha-renames session, generation,
operation, effect, and revision references. It retains behaviorally relevant
pending effects, bounded late-result tombstones, model environment, and ghost
obligations while excluding allocators, sequence/time magnitude, diagnostic
counters and prose, and trace data. Digests use a deterministic FNV-1a encoding;
Swift's randomized hash order is never persisted.

The late-result pool is bounded by profile. Completed effect IDs outside that
pool cannot be named again and are intentionally quotiented away. Any change to
this abstraction or an action inventory requires incrementing the affected
`PlaybackSearchModelDefinition.modelVersion` and reviewing the PR baseline.

## Models and owner-policy contracts

- Seek searches exact/keyframe/preview/relative requests, supersession,
  pause/EOF/shutdown boundaries, prerequisite permutations, and delayed,
  duplicate, stale, mismatched, failed, and cancelled results.
- EOF/drain fixes A/V, video-only, audio-only, and empty required sets and checks
  drain orders, duplicate same-cycle progress, new-generation rearm, and
  at-most-once playlist advancement.
- Recovery checks two bounded hardware-decoder resume attempts followed by one
  hardware-to-software fallback per lineage, presentation recovery, executor
  prerequisites, interrupts, revision fences, and old-output rejection.
- Track/subtitles retains explicit rejection of an in-flight selection and
  checks commit/rollback, invalid and wrong-kind requests, external source
  install/invalidation, and overlay revision fencing.
- Stop/shutdown checks cleanup-only monotonic shutdown, duplicate commands,
  late callbacks, resource custody, and explicit bounded external-wait states
  for cancellation or finalization failure.
- Preroll/buffering uses one current-generation startup obligation as playback
  authority and separately searches partial/absent streams, starvation/refill,
  queue bounds, format repreroll, and control preemption.

Every core transition runs `PlaybackInvariantChecker` plus transition-local
search invariants before state deduplication. Statelessness records them as
transition checks. There is no counterexample allowlist.

## Progress, POR, and profiles

Graphs are classified into intentional stable waits, named external waits,
measured transaction progress, unmeasured states, and stuck states.
`PlaybackProgressPolicy` supplies the playback predicates and obligation
ranks. Statelessness progress analysis supplies fair-edge reverse
reachability, strongly connected components and closed-component detection.
It rejects closed nonterminal no-progress cycles without treating an
event-driven wait as deadlock. A node is unmeasured when its outgoing edges are
not all known, and an unmeasured node is never evidence either way.

Partial-order reduction is deliberately narrow. `PlaybackReductionPolicy`
marks only `wrongOperation` result mutations as eligible. Statelessness still
executes and checks every edge, and it collapses one only when the disposition,
every check, the playback projection and the successor are equal. Validation
mode also executes enabled-action diamonds and reports noncommuting pairs.
Reduction policy version 2 declares same-stream queue offer/consume pairs
dependent: they do not commute at queue bounds, and neither action is ever
reduced. Those diamonds are reported as `declaredDependentDiamondCount`. Any
other noncommuting pair is a validation failure.
Tests compare reduced and unreduced searches with `compareReduction`,
including progress. PR stays unreduced so the baseline continuously checks the
full graph.

| Profile | Depth | Generations | Pending / late | Failures | States | Edges | POR |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| PR | 12 | 2 | 4 / 2 | 1 | 50,000 | 500,000 | off |
| Nightly | 20 | 3 | 6 / 4 | 2 | 500,000 | 5,000,000 | conservative |
| Qualification | 28 | 4 | 8 / 6 | 3 | 2,000,000 | 25,000,000 | validation |

The limits are conservative starting values. Split a scenario into a named seed
when its cross-product reaches a cap; do not sample schedules. The checked-in PR
baseline allows 25 percent state/edge drift but rejects normalization digest
changes without a model-version increment, missing seed entries, model-version
regression, invariant/progress findings, and cap hits.

EOF/drain model version 9 isolates stop, shutdown, seek, and replacement
interruptions into named `draining-*` seeds. This preserves exhaustive schedule
coverage while preventing the unrelated interruption cross-product from
exhausting the PR state cap.

EOF/drain model version 10 makes playlist advancement depend on a successful
checkpoint result. The other models also increment their versions because they
share the same core transition semantics; failed and stale checkpoint results
must not advance playback.

Recovery scenarios that model software fallback supply the production consecutive
failure threshold. A transient hardware retry does not construct a software-active
seed. Unit coverage constructs every advertised seed to catch this kind of drift.

## Commands and artifacts

Run every PR seed through the build queue (the runner compiles first):

```sh
python3 /Volumes/seed1/Projects/kyoto/kyoto.py submit -- ./Scripts/run-playback-state-space.sh
```

Select a model/seed directly or validate POR:

```sh
swift run IlliquidStateSpaceExplorer --profile validation \
  --model seek --seed ready-playing --por validation \
  --output /tmp/illiquid-state-space
```

Nightly and deterministic sharding use environment variables:

```sh
ILLIQUID_STATE_SPACE_PROFILE=nightly \
ILLIQUID_STATE_SPACE_SHARD_INDEX=0 \
ILLIQUID_STATE_SPACE_SHARD_COUNT=6 \
  ./Scripts/run-playback-state-space.sh
```

`ILLIQUID_STATE_SPACE_MAX_GRAPH_BYTES` (default 3 GiB) bounds Statelessness
graph bookkeeping. Reaching it ends the search as
`incomplete(graph_retention_limit)` rather than exhausting host memory.
`ILLIQUID_STATE_SPACE_SEEDS="model/seed ..."` selects seeds.
`ILLIQUID_STATE_SPACE_TIME_LIMIT=SECONDS|none` overrides the profile's
per-seed time budget. The effective configuration is recorded in each record,
so an untimed run can never pass as a profile run.

Measured cost budgets per profile (wall time, peak RSS, deadlines) are in
[PLAYBACK_STATE_SPACE_COST_BUDGET.json](Baselines/PLAYBACK_STATE_SPACE_COST_BUDGET.json).
They are resource limits, not acceptance criteria. Each record carries
`elapsedSeconds`.

Exit 0 means every selected search finished within bounds without a finding.
Exit 1 means an invariant, progress, POR, trend or unretained-finding failure.
Exit 2 means an incomplete search (cap, deadline or graph budget).

The runner writes a provenance file: revision, a SHA-256 for every dirty file,
and Swift and platform identity. It also writes one qualification record per
seed and a shard manifest. Each record carries engine revision, model, property
and codec versions, effective configuration, termination, coverage, counts,
progress and trend results. `--resume` reuses a record only if all of those
identities and the graph budget match, and the run finished.

Each failed property produces a `PlaybackVerificationArtifact`. It holds the
provenance, the first finding, and the original and minimized witnesses. The
witness is minimized with native `shrink64`, or with `shrinkContinued` when the
witness crosses an earlier failure. The artifact also holds both witnesses as
`stateless.continued-trace-json` traces, using the versioned deterministic
`PlaybackModelCodec`. `IlliquidStateSpaceExplorer --replay ARTIFACT` replays
both traces in a fresh process. Replay compares every step's disposition,
outputs, post-state and checks, and requires the minimized trace to end with
the selected property.

`--convert-legacy FILE` reads schema-1 artifacts from the retired explorer,
re-executes their actions through the Statelessness model, and lists the
fields it cannot preserve. Original files are never modified. An artifact from
an older model version must be replayed in its pinned historical checkout.
`PlaybackRuntimePromotion` converts only faithful command/result/current-fact
witnesses to a runtime schedule with unchanged effect contexts.
Executor-only, abstract queue, and resource-custody actions are rejected until
a real native fault seam exists.

## Qualification relationship

`Scripts/run-native-qualification.sh` runs the qualification profile before
fixture generation, differential smoke, the full Swift suite, long A/V gates,
ASan/TSan stress, architecture checks, and packaged-app verification. External
mpv oracle, renderer-capable host, real media, and physical display/audio/device
results remain separately measured or explicitly blocked; a bounded core search
never upgrades those gates.
