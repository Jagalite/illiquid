# Playback bounded state-space search

Superplayr includes a deterministic, custom Swift explorer around the production
`PlaybackCore.update(_:)` transition. It exhausts finite policy schedules; it is
not a media simulator and does not add a general model-checking dependency.

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

The default kernel is layered, state-aware breadth-first search with stable
action ordering, predecessor reconstruction, and hard state/edge/depth caps.
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
search invariants before state deduplication. There is no counterexample
allowlist.

## Progress, POR, and profiles

Completed graphs are classified into intentional stable waits, named external
waits, measured transaction progress, cutoff/unmeasured states, and stuck
states. Fair-outcome reverse reachability, obligation ranks, and Tarjan SCC
analysis reject closed nonterminal no-progress cycles without treating an
event-driven wait as deadlock.

Partial-order reduction is deliberately narrow: only actions proven to have the
same successor and observation signature are collapsed. Validation mode also
executes enabled-action diamonds and counts noncommuting pairs. Tests compare
POR-on and POR-off reachable-key digests and failures at an exhaustive small
bound. PR stays unreduced so the baseline continuously checks the full graph.

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

Run every PR seed:

```sh
./Scripts/run-playback-state-space.sh
```

Select a model/seed directly or validate POR:

```sh
swift run SuperplayrStateSpaceExplorer --profile validation \
  --model seek --seed ready-playing --por validation \
  --output /tmp/superplayr-state-space
```

Nightly and deterministic sharding use environment variables:

```sh
SUPERPLAYR_STATE_SPACE_PROFILE=nightly \
SUPERPLAYR_STATE_SPACE_SHARD_INDEX=0 \
SUPERPLAYR_STATE_SPACE_SHARD_COUNT=6 \
  ./Scripts/run-playback-state-space.sh
```

Exit 0 means every selected search completed within bounds without a finding;
exit 1 means an invariant, progress, POR, or trend finding; exit 2 means a cap.
Success writes one summary per seed and a shard manifest. Each safety finding
writes deterministic JSON with source/dirty identity, configuration, full
production pre/post replay states, normalized digests, original and causally
minimized traces, and minimization replay history.

`PlaybackSearchArtifactReplayer` rebuilds the seed and replays every action
through the production core. `PlaybackRuntimePromotion` converts only faithful
command/result/current-fact traces to a runtime schedule with unchanged effect
contexts. Executor-only, abstract queue, and resource-custody actions are
rejected until a real native fault seam exists.

## Qualification relationship

`Scripts/run-native-qualification.sh` runs the qualification profile before
fixture generation, differential smoke, the full Swift suite, long A/V gates,
ASan/TSan stress, architecture checks, and packaged-app verification. External
mpv oracle, renderer-capable host, real media, and physical display/audio/device
results remain separately measured or explicitly blocked; a bounded core search
never upgrades those gates.
