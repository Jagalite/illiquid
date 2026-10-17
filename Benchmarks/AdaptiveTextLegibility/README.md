# Adaptive text legibility performance research

This harness compares the numeric work of an uncached adaptive text style against
the frozen implementation from
[`8c3cc3d4008d5d1b8d436bcf2d51d891382b6548`](https://github.com/Jagalite/illiquid/commit/8c3cc3d4008d5d1b8d436bcf2d51d891382b6548).
The candidate is the actual working-tree
`Sources/IlliquidApp/UI/AdaptiveTextLegibility.swift`.

The final candidate replaces repeated opacity percentile sorts with an equivalent
threshold decision and reuses the foreground luminance within that search. It
retains the original initialization, exact score calculation, and an exact-score
fallback for foreground components outside the optimized numeric domain.

## Source fidelity

`run.py` compiles the complete production `VideoColorSample.swift` as the
`IlliquidCore` module. It extracts `PlayerRainbowPalette` and
`AdaptiveRainbowTextColor` verbatim from the production `PlayerTheme.swift`, into
one support file so their `fileprivate` relationship remains intact. It then
compiles the baseline and candidate separately with this shared support and
`Driver.swift`, using `-O -whole-module-optimization`. There are no behavior stubs
or fetched package dependencies.

Each output directory records the compiler, flags, environment, exact commands,
source copies and SHA-256 digests, and executable/library digests. The baseline
file has its own checked-in source manifest. Source extraction intentionally fails
if its declaration boundaries change.

## Reproduce

Use a Swift toolchain with Swift Testing support and Python 3.10 or later. Select
`swiftc` through `PATH`, `SWIFTC`, or `--swiftc`. Output directories must be fresh.

```sh
python3 Benchmarks/AdaptiveTextLegibility/run.py \
  --output /tmp/illiquid-legibility-results \
  --rounds 8 --target-ms 150 --receipt-samples 320 \
  --cases all --kernels style_miss,init_score
```

On Linux, optionally add `--cpu N` to pin timed processes to an allowed CPU. The
recorded final run used CPU 2. This option is not supported on macOS. The runner
records the allowed CPU set and the affinity of each timed process.

Run the exact new app tests in an isolated package in both debug and release:

```sh
python3 Benchmarks/AdaptiveTextLegibility/run.py \
  --output /tmp/illiquid-legibility-tests --tests-only
```

The package copies the actual candidate, shared production support, and
`Tests/IlliquidAppTests/AdaptiveTextLegibilityPerformanceTests.swift`, with
warnings treated as errors. Its macOS deployment target is 26.0. On Linux, it uses
SwiftPM's integrated driver to avoid the standalone driver's restricted `/proc`
inspection in the research sandbox. This isolated package verifies the numeric
implementation; the main app's native build and UI tests remain separate.

For an untimed differential run, pass `--receipts-only --receipt-samples 320`.
`--list-cases` lists the fixtures. `--cases` accepts comma-separated names, and
`--kernels` also supports `score` and `opacity` for focused diagnosis.

## Workloads and measurement

The primary `style_miss` kernel follows the numeric call graph of
`PlayerTextPalette.uncachedColors` and `resolvedComponents`:

1. Initialize a context and resolve the primary color.
2. Initialize the second context used by the caller.
3. Resolve secondary and tertiary opacities with preferences 0.96 and 0.90.

The two initializations deliberately stay separate. The output color and both
opacities contribute to an observed checksum. Region extraction, hue/sample
preparation, UI color construction, palette-cache lookups, and video decoding are
outside the timer.

There are 22 fixtures: rainbow and monochrome variants of one sample; nine-sample
bright, dark, and midgray regions; a 32-sample saturated region; 96-sample bright,
dark, midgray, mixed, and varied regions; and 224 samples representing 96 video
samples plus 128 black letterbox samples. Initialization expands each source
sample into the production source/darkened/lifted endpoints. Each fixture rotates
through eight seeded sample sets and previous-color variants. Rainbow style
misses rotate through all six palettes.

`init_score` is a low-reuse negative control: construct a context and make one
score query. Its initialization and scoring definitions are unchanged in the
final candidate. `score` measures queries on prepared contexts. `opacity` measures
both subordinate opacity decisions on prepared contexts and foregrounds.

For each workload, the baseline calibrates a shared iteration count. Both builds
use that count and perform in-process warmup before measurement. Each observation
comes from a fresh process. Even rounds run baseline/candidate and odd rounds
candidate/baseline; workload order rotates between rounds. Wall time and process
CPU time are recorded separately. Formatting, receipt emission, assertions, and
process startup are outside the measured loop. Every timed pair must produce the
same checksum.

Exact decision receipts run separately from timing. The final corpus contains
320 seeded samples × six palettes × two modes = 3,840 rows. It includes empty
regions, duplicate colors, prior colors, multiple region sizes, clamped and
nonfinite lifts/preferences, direct scores, opacity scores, and readable-opacity
decisions. Floating-point outputs are compared as bit patterns, without a
tolerance. The independent sorted-reference tests additionally cover percentile
boundaries, equality at the contrast threshold, and background/luminance pairing.

## Recorded results and limits

The predefined final cohort is in [`evidence/final/summary.json`](evidence/final/summary.json),
with all observations in
[`evidence/final/measurements.jsonl`](evidence/final/measurements.jsonl).
It uses eight balanced rounds at a 150 ms calibration target and the unchanged
22-case, two-kernel protocol. These are isolated numeric kernel measurements,
not measurements of the macOS player or total application CPU use.

The recovered final run used Swift 6.3.2 on Linux x86-64, with a reported AMD
EPYC 9V74 processor. Selected full-style medians, in microseconds per numeric
style miss:

| Workload | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| One sample, rainbow | 8.66 | 5.98 | -30.9% |
| Local nine, bright rainbow | 40.08 | 28.40 | -29.1% |
| Overall 96, bright rainbow | 377.64 | 272.48 | -27.8% |
| Overall 96, bright monochrome | 136.32 | 132.26 | -3.0% |
| Overall 96, dark monochrome | 120.44 | 109.68 | -8.9% |
| Overall 96, mixed rainbow | 48.09 | 47.49 | -1.2% |
| Overall 96, midgray rainbow | 115.17 | 120.20 | +4.4% |
| Letterbox 224, rainbow | 186.77 | 186.87 | +0.0% |

The first three workloads improved in every paired round. Smaller differences
need caution: unchanged `init_score` control medians ranged from -3.6% to
+4.9%. The midgray rainbow candidate/baseline paired ratios spanned
0.98–1.13; letterbox rainbow spanned 0.98–1.20. Both cross parity.
Wall and process CPU measurements are retained for every observation. The
evidence supports a reduction in the strongest opacity-search workloads; it does
not establish a universal gain. Native measurements are needed to qualify macOS
performance and any app-level impact.

All 3,840 decision receipts matched exactly in the recovery run. The recovered
exact-source tests also passed in debug and release: six tests in each
configuration, with warnings treated as errors.

## Evidence recovery

An external workspace reset during PR preparation removed the original final
run's 704 raw timing observations and its generated artifacts. The exploratory
checkpoints survived outside that workspace. The final runner and driver were
recovered from authored tool history and those source checkpoints, and the
candidate's original SHA-256 was verified. The identical predefined final cohort
was rerun to recover auditable evidence, with no posthoc workload exclusions or
selection of favorable rounds. See [`evidence/recovery.json`](evidence/recovery.json).
The lost final observations are not reconstructed or presented as current data.

Both short exploratory runs remain under `evidence/exploratory-*`. The first also
tried pre-sorting luminances for opaque scores. The final candidate excludes that
extra storage and initialization work. The noisy exploratory runs do not
establish that the additional sorting caused their unfavorable measurements.

Compact manifests, summaries, raw timing records, differential results, and test
logs are intended for version control. Full source snapshots, exact commands, and
complete baseline and candidate decision streams remain in each local output
directory and in CI artifacts. Source and decision-stream hashes are recorded in
the compact evidence. A second complete local copy is retained outside the
checkout after the recovery run.
