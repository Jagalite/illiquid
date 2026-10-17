# Subtitle memory budget experiment

This benchmark compiles the **complete, unchanged production source** for each
variant with the same Swift harness. It measures the memory-budget API, including
its existing lock, weak lease reference, and admission checks. It does not decode
media, pack subtitle pixels, or measure the whole player.

The accepted change returns early from an unchanged-size lease resize. The
cached-total alternative in `experiments/CachedTotals.swift` is a rejected
experiment, not a production implementation.

See [the research report](../../Documentation/SUBTITLE_MEMORY_BUDGET_RESEARCH.md)
for results, workload context, negative controls, and qualification limits.

## Reproduce

With Swift 6.1 or newer on `PATH`:

```sh
bash Scripts/test-subtitle-memory-budget.sh --configuration debug
bash Scripts/test-subtitle-memory-budget.sh --configuration release
SUBTITLE_BUDGET_SOURCE=Benchmarks/SubtitleMemoryBudget/baseline/SubtitleMemoryBudget.swift \
  bash Scripts/test-subtitle-memory-budget.sh --configuration release

python3 Benchmarks/SubtitleMemoryBudget/run.py \
  --output /tmp/subtitle-budget-final \
  --rounds 8 --iterations 1000000 --counts 1 2 5 9 128 \
  --scenarios resize-unchanged resize-changing resize-rejected acquire-release
```

Use a new output directory for each invocation. The runner records compiler and
source hashes, compile commands, platform, process order, individual timings,
behavior receipts, and both ratio-of-medians and paired-median comparisons.
It uses `-O -whole-module-optimization`, a common module name, and deterministic
Swift hashing. Each timing observation is a fresh process. AB/BA ordering is
balanced for every scenario/count combination; cells are shuffled per round.

The fixture keeps all initial leases alive. It uses the five real owner categories
and 4 KiB reservations to isolate bookkeeping cost; these are not measured
subtitle image sizes. The 2/5/9 counts approximate text-pipeline ownership shapes.
The 128 count represents dense bitmap retention stress. Acquisition and release
churn adds one short-lived bitmap lease to the indicated live count.

To inspect the rejected cached-total design and the same-size-only ablation:

```sh
python3 Benchmarks/SubtitleMemoryBudget/run.py \
  --output /tmp/subtitle-budget-three-way \
  --candidate-source Benchmarks/SubtitleMemoryBudget/experiments/CachedTotals.swift \
  --include-noop-control --rounds 6 --iterations 100000
```

The original exploration used distinct compiler module names; the current runner
deliberately removes that unnecessary difference. Its exact historical compile
commands and hashes remain in `evidence/linux/exploration/manifest.json`. Treat
that short exploration as candidate selection, not a precise forecast.

## Evidence

- `baseline/SubtitleMemoryBudget.swift`: byte-identical to production Git blob
  `7694b209c13e86406fc2eac6bef2c7ed09974569` from main commit
  `8c3cc3d4008d5d1b8d436bcf2d51d891382b6548`. The runner checks this blob hash.
- `evidence/linux/final/`: 320 final timing processes, eight paired rounds,
  1,000,000 operations per process, source and binary receipts.
- `evidence/linux/exploration/`: 756 shorter processes across three candidates,
  including rejected alternatives and snapshot/preflight controls.
- `evidence/linux/tests/`: complete logs for baseline and candidate in debug and
  release. This container required `SWIFT_USE_OLD_DRIVER=1` because its default
  Swift driver crashed while accessing process statistics. This workaround is
  not needed by the benchmark's direct `swiftc` invocation and is not hardcoded
  into the portable test runner.

Raw timing files are losslessly compressed JSON Lines. For example:

```sh
gzip -dc Benchmarks/SubtitleMemoryBudget/evidence/linux/final/measurements.jsonl.gz
```

`.github/workflows/subtitle-memory-budget.yml` repeats the budget tests and final
benchmark on macOS and separately builds the app graph with native subtitle
consumer regressions. Timing differences are evidence, not a flaky CI threshold.
