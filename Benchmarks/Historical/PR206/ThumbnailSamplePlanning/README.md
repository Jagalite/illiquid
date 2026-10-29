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
- Retain exact-level 32/64, one-sample, and too-short-to-fill controls. The final
  revision adds four more short-clip controls after the initial findings. Inputs
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

## Chunked portable result: one remaining control regression

[Run 40640044957](https://github.com/Jagalite/illiquid/actions/runs/40640044957)
tested the chunked candidate at `7d8d0dec73d75c80695b2fc0ecaad10bb5a30644`
on x86_64 Linux with Swift 6.4. All correctness checks passed again.
Storyboards improved by 25.9%, balanced-12 by 27.0%, and extensive-24 by 31.9%
in median paired CPU. Exact-level-32 regressed by 1.5%; exact-level-64 improved
by 0.6%; maximum-64 improved by 4.2%. The 0.1-second control regressed by
10.14%, so this candidate also failed the unchanged 10% control limit.
All 200 observations are in [the chunked receipt](results/linux-chunked.json).

These two runs used different Swift versions and runner kernels. Their samples
are not pooled, and absolute timings are not compared across hosts. Within each
run, baseline and candidate used the same compiler, flags, and input corpus.

The next revision bounds the target by the number of available half-second
slots when that number is smaller than the requested budget. Once those slots
are present, further attempts can only deduplicate. The conversion to an integer
is guarded by `last < Double(limit) / 2`, which keeps it within 0...63 even
for very large durations. It retains the first-occurrence timestamp bits.

Four additional count-64 controls use durations 1.4, 2.1, 7.9, and 30 seconds
with varied focus positions. They extend the control gate using the same 10%
regression limit; every earlier workload and both primary thresholds remain.
This tests the general underfilled-plan case instead of only the original
0.1-second fixture.

## Final portable result: performance gate passed

[Run 40640869019](https://github.com/Jagalite/illiquid/actions/runs/40640869019)
tested the final source at `7886cda021bfc14e98616d0dc2cb8b582cdccd49`
on x86_64 Linux with Swift 6.4.1. It passed the original primary criteria and
the expanded control gate. Both primary workloads improved in all ten pairs.

| Workload | Baseline CPU µs/call | Candidate CPU µs/call | Median paired CPU reduction | Faster CPU pairs |
| --- | ---: | ---: | ---: | ---: |
| storyboard-24 | 0.852 | 0.603 | 29.7% | 10/10 |
| economical-6 | 0.289 | 0.210 | 27.3% | 10/10 |
| balanced-12 | 0.450 | 0.330 | 26.3% | 10/10 |
| extensive-24 | 0.885 | 0.604 | 31.5% | 10/10 |
| maximum-64 | 2.466 | 2.381 | 3.5% | 10/10 |
| boundary-33 | 2.382 | 0.904 | 62.1% | 10/10 |
| exact-level-32 | 0.830 | 0.860 | -3.6% | 0/10 |
| exact-level-64 | 2.351 | 2.387 | -1.5% | 1/10 |
| one-sample | 0.140 | 0.057 | 59.0% | 10/10 |
| short-duration | 0.746 | 0.058 | 92.2% | 10/10 |
| short-1.4 | 0.794 | 0.104 | 86.9% | 10/10 |
| short-2.1 | 0.981 | 0.183 | 81.3% | 10/10 |
| short-7.9 | 1.642 | 0.392 | 76.2% | 10/10 |
| short-30 | 4.207 | 2.208 | 47.6% | 10/10 |

Positive reductions mean faster; negative values mean slower. Per-variant
timings are marginal medians, while reductions are medians of paired percentage
changes. The two summaries need not be identical ratios. All raw observations,
ranges, calibration data, compiler details, source hashes, and exact output
receipts are in [the final receipt](results/linux-final.json).

The exact-level controls retain small costs: approximately 30 ns/call at 32
samples and 36 ns/call at 64 samples. These are 3.6% and 1.5% median paired CPU
regressions, respectively, within the predeclared 10% ceiling. The result is
therefore a tradeoff, not a claim that every workload is faster.

Validation passed:

- 53,075 bitwise differential cases in each of debug and release.
- Three selected-source unit suites in both configurations, including the
  existing policy/scheduling coverage and the new sample-planning cases.
- All 448 timing-corpus outputs matched exactly (14 workloads × 32 inputs).
- All paired checksums matched across 280 timing observations.

The two earlier failed experiments remain above with their full receipts.
No observations were dropped or pooled across compiler/runner environments.

### Native status and limits

The macOS 26 workflow was submitted but remained queued when these results were
recorded. This supports a draft PR based on successful portable component
research; native performance confirmation is still pending. The workflow is
[defined here](../../.github/workflows/thumbnail-sample-planning.yml).

These measurements concern an optimized, warmed planner benchmark, including
the common result consumer. The normal storyboard saving was about 0.25 µs per
call on this runner. This is not a measured improvement in hover latency,
decoding, playback smoothness, startup, energy use, or the complete macOS app.
