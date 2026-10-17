# Subtitle memory-budget benchmark

This benchmark measures actual Swift reservation bookkeeping. It does not run
libass, allocate matching pixel buffers, or measure playback, RSS, or energy.

See [the research report](../../Documentation/SUBTITLE_MEMORY_BUDGET_PERFORMANCE.md)
for the decision, results, production callsites, and limits.

## Run

With Swift 6.1 or newer on `PATH`, from the repository root:

```sh
bash Scripts/test-subtitle-memory-budget.sh --jobs 2 -Xswiftc -warnings-as-errors
bash Scripts/test-subtitle-memory-budget.sh --jobs 2 -c release -Xswiftc -warnings-as-errors
python3 Benchmarks/SubtitleMemoryBudget/run.py --output /tmp/illiquid-budget-results
```

The output directory must not already exist. The runner builds three isolated
executables, uses explicit Swift 6 language mode by default, then performs six
balanced rounds with 500,000 timed operations per fresh process. It records
source/binary/compiler identities, raw JSONL observations, and a median/range
summary. Receipt or final-state mismatches fail the run. Build and run arguments
are recorded in `manifest.json`.

The variants are:

| Label | Implementation |
|---|---|
| `baseline` | Frozen original production source from `8c3cc3d`, verified by Git blob hash |
| `same-size-only` | Original source plus an early return for unchanged resizes |
| `candidate` | Current production source, or the explicit `--candidate-source` input |

The default live counts are 1, 4, 32, and 128. One staging lease is resized;
three additional leases use the other libass/staging owners, followed by bitmap
event leases. These are synthetic reservation fixtures. The acquisition/release
workload temporarily adds one more bitmap lease. Both small and dense sets are
included so a favorable large-set result cannot hide a small-set regression.

## Preserved rejected experiment

`experiments/CachedSubtitleMemoryBudget.swift` contains the rejected cached-total
prototype, outside production targets. Reproduce its initial language mode with:

```sh
python3 Benchmarks/SubtitleMemoryBudget/run.py \
  --candidate-source Benchmarks/SubtitleMemoryBudget/experiments/CachedSubtitleMemoryBudget.swift \
  --swift-language-version 5 \
  --output /tmp/illiquid-budget-cached-results
```

In `evidence/cached-experiment`, the label `candidate` means this rejected
prototype. In `evidence/final-linux`, `candidate` means the final production
single-pass implementation. Each cohort has its own baseline, source identities,
and compiler commands; compare variants within a cohort.

`evidence/validation` retains debug/release and original-source equivalence logs,
plus a deliberately broken resize diff and the resulting failed test. Those
files are evidence, not changes to apply to the player.

The macOS workflow uploads equivalent platform-specific evidence separately.
Timings are informational; the workflow does not enforce a noisy speed threshold.
