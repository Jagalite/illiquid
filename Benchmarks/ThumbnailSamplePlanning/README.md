# Thumbnail sample planning

## Question

The sample planner fills complete dyadic subdivision levels, then truncates the
result to the requested count. The 24-image storyboard can therefore calculate
and deduplicate timestamps that are discarded. The candidate returns as soon as
the requested prefix is complete. It retains focus priority, half-second
quantization, duplicate suppression, count bounds, and the 128-division limit.

The player invokes this planner from [automatic thumbnail preparation](../../Sources/IlliquidApp/App/ThumbnailBackgroundScheduler.swift)
and from [storyboard fallback lookup after a thumbnail cache miss](../../Sources/IlliquidNativePlayback/Media/NativeTimelineThumbnailGenerator.swift).
The background presets request 6, 12, or 24 samples; the storyboard requests 24.

This is a bounded planning component. It does not change which frames are
decoded, thumbnail quality, cache behavior, or rendering. Component timings do
not establish a visible playback, startup, battery, or end-to-end decoding gain.

## Reproduce

From a checkout containing baseline commit
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`:

```sh
python3 Benchmarks/ThumbnailSamplePlanning/run.py \
  --output /tmp/thumbnail-sample-planning --pairs 10 --target-ms 250
```

The output directory must be new or empty. Use `--tests-only` for differential
and focused unit checks. Builds are serialized in an isolated output directory.
Use the repository's Kyoto queue when available; the hosted workflow reports
its absence before compiling directly.

## Method and decision rule

- Verify the frozen baseline against its Git blob hash. Compile the unmodified
  baseline and candidate production policy files as separate optimized modules
  with the same module name and flags. The benchmark imports the public API;
  there is no cross-module optimization or replacement implementation.
- Run a bitwise differential check in debug and release over boundary values
  and 20,000 seeded cases, including extreme counts, nonfinite inputs, signed
  zeros, quantization collisions, and existing overflow behavior. Run the
  existing policy/scheduling suites and the new sample-planning suite in both
  configurations using a temporary package containing the actual source files.
- Compare every timestamp in the 32-input timing corpus for each workload.
  Time the real storyboard entry point and sample requests at preset budgets
  6, 12, and 24, plus maximum and subdivision-boundary workloads.
- Retain exact-level 32/64, one-sample, and too-short-to-fill controls. Inputs
  are constructed before timing. The result consumer reads every timestamp.
  These synthetic workloads are not a measured user-duration distribution.
- Use ten fresh-process pairs, alternate baseline/candidate order, and rotate
  workload order. Each process warms up for 1,000 calls. Baseline calibration
  selects the same iteration count for both variants, targeting 250 ms.
  Measure wall time and process CPU time and retain every calibration and pair.
- Require at least 15% median paired CPU reduction and at least 9/10 winning
  pairs for both storyboard-24 and balanced-12; no control may regress by more
  than 10% in median paired CPU. This predeclared practical consistency rule is
  not a statistical-significance test. Report all workloads, including losses.

The evidence receipt records source/compiler/host details, validation results,
binary hashes, every observation, medians and ranges, and paired reductions.
The workflow retains command logs and exact source snapshots as an artifact.
Compilation and component-test success are separate from a performance-gate
pass. Full-app builds and live playback are outside this experiment.

## Initial portable result: rejected

[Run 40639460139](https://github.com/Jagalite/illiquid/actions/runs/40639460139)
tested the per-sample-check candidate at
`41e95be7893aa22248b86cd9be4e054bad45cdc5` on x86_64 Linux with Swift 6.4.1.
All 53,075 bitwise differential comparisons passed in each of debug and release,
all three selected-source unit suites passed in both configurations, and the
320 timing-corpus outputs matched. The run collected 200 timing observations.

The first candidate improved storyboard-24 by 23.6% and balanced-12 by 30.1%
in median paired CPU, with 10/10 winning pairs each. However, exact-level-32
regressed by 16.0%, exact-level-64 by 24.2%, and maximum-64 by 19.2%. It failed
the predeclared control gate and is not accepted. Every observation is retained
in [the initial receipt](results/linux-initial.json).

The revised candidate attempts bounded chunks of at most the remaining sample
budget. Each attempt can append at most one timestamp, so a chunk cannot
overshoot. If quantized duplicates leave room, the next chunk continues the
same subdivision sequence. This avoids a completion branch inside each sample
iteration. The baseline, workload matrix, and acceptance rule remain unchanged.

Revised portable and native measurements are pending. No production performance
claim is made from the rejected initial candidate.
