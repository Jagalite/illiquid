# Adaptive text legibility performance research

The later [palette context reuse study](../Benchmarks/AdaptiveTextPaletteReuse/README.md)
removes the duplicate context construction described below. This report and its
numeric `style_miss` kernel preserve the call sequence used for the original
opacity-threshold experiment; the follow-up measures the actual palette method
and its cache paths.

## Decision and scope

Optimize the opacity threshold search used by adaptive Liquid Glass text. The
production change is confined to
[`AdaptiveTextLegibility.swift`](../Sources/IlliquidApp/UI/AdaptiveTextLegibility.swift).
It preserves the original contrast model, color selection, opacity decisions,
and ten-step binary search. The measured benefit is lower numeric computation
time for some uncached text styles; this investigation does not measure overall
player CPU, frame rate, power consumption, or memory usage.

The frozen baseline is commit
`8c3cc3d4008d5d1b8d436bcf2d51d891382b6548`. Both executables use the same current
supporting sources and differ only in the legibility implementation. The report
and benchmark are independent of the playback, thumbnail, persistence, and
filesystem performance work elsewhere in this repository.

## Where the work occurs

At this study's baseline,
[`PlayerTextPalette.uncachedColors`](../Sources/IlliquidApp/UI/PlayerTheme.swift)
resolved primary text using one legibility context, then constructed a second
context to choose secondary and tertiary opacities, preferring 0.96 and 0.90.
The benchmark includes both context initializations, primary resolution, and
both opacity calls. Each context expands every background into the source,
darkened, and lifted alternatives used by the existing conservative glass model.

This work is associated with cache misses. The style cache holds up to 256
entries and clears on a new sample revision. The
[`VideoFrameColorSampler`](../Sources/IlliquidNativePlayback/Presentation/VideoFrameColorSampler.swift)
normally samples a 12-by-8 grid at a minimum interval of 0.25 seconds and
suppresses insignificant updates. Geometry and palette changes can also produce
new keys. These facts limit the app-wide impact: the benchmark is not evidence
that every video frame pays this cost.

## Change and equivalence argument

The original `readableOpacity` repeatedly asks `opacityScore` for a numerical
10th-percentile contrast score, although the search only needs to know whether
that score meets 4.5. Each query creates an array of ratios, evaluates both
blending models for every sample, and sorts the array.

For `n` expanded backgrounds, the existing percentile index is
`k = Int(Double(n - 1) * 0.10)`. Its sorted ratio meets the threshold exactly
when at most `k` ratios fail the threshold. The new private predicate counts
failures and returns false as soon as their number exceeds `k`.

The per-background score is the minimum of the gamma-blended and
linear-blended contrasts. For finite normalized RGB, both must meet 4.5. The
predicate evaluates the cheaper linear expression first and skips gamma
conversion when that expression already fails. It keeps each RGB background
paired with its original luminance and uses the same arithmetic and threshold
comparisons as the original path. It also computes foreground luminance once
per opacity search.

The numerical `score` and `opacityScore` APIs, initialization, primary-color
resolution, and stored arrays remain as before. Raw foreground components
outside `[0, 1]`, including nonfinite values, retain the old numerical path;
this preserves the original distinction between the initial `< 4.5` check and
the midpoint `>= 4.5` check when NaNs occur. Preferred-opacity sanitization,
the opaque-text guard, the quantile rounding rule, and all ten bisections also
remain intact. No new cache or stored sorted copy is introduced.

## Experiment

[`run.py`](../Benchmarks/AdaptiveTextLegibility/run.py) compiles the complete
`VideoColorSample.swift` into a shared `IlliquidCore` module. It extracts the
actual `PlayerRainbowPalette` and `AdaptiveRainbowTextColor` declarations from
`PlayerTheme.swift`, then builds separate baseline and candidate executables
using `swiftc -O -whole-module-optimization`. It does not replace production
color types with behavior stubs. Source snapshots, SHA-256 hashes, compiler
commands, binary hashes, and platform information accompany generated output.

The predefined cohort contains 22 cases: eleven regions in both rainbow and
monochrome modes. Region sizes are one sample, nine local samples, 32 leading
samples, 96 overall samples, and a 224-sample letterbox stress case. Distributions
cover bright, dark, middle gray, saturated, black/white mixed, and varied colors.
The stress case combines 96 varied samples with 128 black samples. Each fixture
cycles eight deterministic input variants and all six actual palettes. Inputs,
hue sampling, and previous-color selection are prepared outside the timed loop.

`style_miss` measures the complete numeric call sequence described above.
`init_score` is an unchanged-path control that creates a context and asks for
one opaque score. Region extraction, cache lookup, SwiftUI color construction,
rendering, sample generation, and decoding are outside the measured scope.

The final Linux cohort uses eight fresh-process rounds, alternating baseline /
candidate and candidate / baseline order and rotating workload order. Each
workload is baseline-calibrated to approximately 150 ms, with the same iteration
count for both versions and warmup before timing. There are 704 timing
observations: 22 cases, two kernels, eight rounds, and two implementations.
Timed checksums must agree for each pair. Both monotonic wall time and process
CPU time are recorded; timed processes are pinned to one allowed Linux CPU.
The host is shared, so affinity does not eliminate frequency, cache, allocator,
or other environmental variability.

## Results

Swift 6.3.2, x86_64 Linux, AMD EPYC 9V74 shared host; timed processes
pinned to logical CPU 2. Values are per complete numeric style miss. Negative
changes mean less time. Wall and process CPU medians are calculated separately.

| Case | Baseline µs | Candidate µs | Wall change | CPU change |
| --- | ---: | ---: | ---: | ---: |
| `one-rainbow` | 8.66 | 5.98 | -30.9% | -30.9% |
| `one-mono` | 3.29 | 2.87 | -12.9% | -12.9% |
| `local9-bright-rainbow` | 40.08 | 28.40 | -29.1% | -29.1% |
| `local9-bright-mono` | 10.79 | 10.56 | -2.1% | -2.1% |
| `local9-dark-rainbow` | 11.58 | 10.99 | -5.2% | -4.7% |
| `local9-dark-mono` | 9.99 | 9.79 | -2.0% | -1.9% |
| `local9-midgray-rainbow` | 11.86 | 11.98 | +1.0% | +0.9% |
| `local9-midgray-mono` | 9.27 | 9.30 | +0.3% | +0.2% |
| `leading32-saturated-rainbow` | 34.90 | 35.18 | +0.8% | +0.8% |
| `leading32-saturated-mono` | 32.65 | 32.66 | +0.0% | +0.0% |
| `overall96-bright-rainbow` | 377.64 | 272.48 | -27.8% | -27.8% |
| `overall96-bright-mono` | 136.32 | 132.26 | -3.0% | -3.5% |
| `overall96-dark-rainbow` | 128.77 | 113.20 | -12.1% | -12.1% |
| `overall96-dark-mono` | 120.44 | 109.68 | -8.9% | -8.9% |
| `overall96-midgray-rainbow` | 115.17 | 120.20 | +4.4% | +4.4% |
| `overall96-midgray-mono` | 108.06 | 105.39 | -2.5% | -2.5% |
| `overall96-mixed-rainbow` | 48.09 | 47.49 | -1.2% | -1.3% |
| `overall96-mixed-mono` | 48.73 | 48.65 | -0.2% | -0.2% |
| `overall96-varied-rainbow` | 96.21 | 98.22 | +2.1% | +2.1% |
| `overall96-varied-mono` | 92.58 | 92.71 | +0.2% | +0.2% |
| `letterbox224-rainbow` | 186.77 | 186.87 | +0.0% | +0.1% |
| `letterbox224-mono` | 182.38 | 186.06 | +2.0% | +2.2% |

The strongest three rainbow cases are 27.8–30.9% faster by wall time, and
candidate time is lower in all eight paired rounds for each of those cases.
The 96-sample bright case saves about 105 µs per numeric style miss. The
96-sample dark rainbow case is also lower in every paired round. These are
localized improvements for cases that spend useful time correcting opacity.

The overall96 middle-gray rainbow case is 4.4% slower in this cohort; several
other cases are effectively neutral or move by small amounts in either
direction. The unchanged initialization-plus-score controls range from -3.6%
to +4.9% by median wall time. Process CPU time broadly follows wall time,
so scheduling alone is not an adequate explanation for the variability. This
experiment supports the targeted improvement and does not establish a universal
speedup or prove that every adverse result is noise. The native workflow gives
a separate platform measurement and must be read alongside this Linux evidence.


All final raw timing observations, summaries, source hashes, and exact-output
checks are checked in under
[`evidence/final`](../Benchmarks/AdaptiveTextLegibility/evidence/final).
These are the complete results of the predefined recovery cohort. A workspace
reset discarded the first full run's raw artifacts before publication. The same
cohort was repeated in full to restore reviewable evidence; results were not
selected or combined across those runs. The provenance and an initial recovery
build failure are preserved under
[`evidence/recovery.json`](../Benchmarks/AdaptiveTextLegibility/evidence/recovery.json)
and `evidence/recovery-build-failure`.

### Alternative considered

An initial combined trial also sorted and stored luminances during context
initialization to accelerate opaque score queries. The retained patch removes
that idea, keeping the change limited to opacity decisions and avoiding added
context storage and initialization work. Its
[`upfront-sorting.patch`](../Benchmarks/AdaptiveTextLegibility/experiments/upfront-sorting.patch)
and short exploratory results remain available for inspection.

The short combined trial showed a mixed-region slowdown, but a shorter
threshold-only comparison and unchanged controls also moved substantially.
Those experiments do not establish that sorting caused the slowdown. They
motivated the broader, longer, balanced cohort; they are not the basis for the
retained patch's final performance claims.

## Correctness and native qualification

The new
[`AdaptiveTextLegibilityPerformanceTests`](../Tests/IlliquidAppTests/AdaptiveTextLegibilityPerformanceTests.swift)
suite contains six tests using an independent full-sort reference. The oracle
derives luminances from RGB and sorts the original ratios rather than reusing
the optimized predicate. It exercises quantile boundaries, exact threshold
equality and adjacent representable values, duplicate and permuted samples,
background/luminance pairing, opacity correction, empty regions, and malformed
or clamped inputs. Multiple region sizes and deterministic random cases provide
thousands of exact comparisons. Debug and release builds treat source warnings
as errors.

The separate differential executable compares full hexadecimal floating-point
receipts for baseline and candidate, including primary RGB, numeric scores,
and preferred or corrected opacity results. The final 320-input sweep produces
3,840 result records spanning six palettes, both color modes, multiple region
sizes and distributions, and nonfinite or out-of-range lift and opacity inputs.
Every record must match bit for bit before timing proceeds. Receipt hashes are
preserved in `evidence/final/differential.json`; full reproducible receipts are
generated locally and in CI instead of committing redundant multi-megabyte files.

The added
[`Adaptive text legibility` workflow](../.github/workflows/adaptive-text-legibility.yml)
runs the same exact-source comparison on macOS 26 with the repository's pinned
Xcode 26.6 setup, using six rounds, an 80 ms target, and 240 differential inputs
(2,880 result records). It then prepares the existing native SDK, builds the
full app graph, and runs the new suite alongside `AdaptiveTextLegibilityTests`,
`AdaptiveRainbowTextColorTests`, and `AdaptiveTextColorAuditTests`. Measurements
and native test logs are uploaded even if a later step fails. Timings are
reported as evidence, without a noisy CI speed threshold. The pull request's
workflow run is the authoritative record of native execution and status.

This investigation does not include Instruments, allocation/RSS measurements,
an energy trace, or an opt-in rendered-window visual qualification. Exact
numeric parity supports unchanged decisions within the tested corpus; it is
not a claim that the glass model measures Apple's material exactly.

## Reproduce

From the repository root with Python 3 and Swift available:

```sh
python3 Benchmarks/AdaptiveTextLegibility/run.py \
  --output /tmp/legibility-results \
  --rounds 8 --target-ms 150 --receipt-samples 320 \
  --kernels style_miss,init_score

python3 Benchmarks/AdaptiveTextLegibility/run.py \
  --output /tmp/legibility-tests --tests-only
```

On Linux, optionally add `--cpu N` for an allowed processor. Use a fresh output
directory for each run; the runner refuses to overwrite a completed manifest.
For the native app tests, follow the dependency setup and exact `swift test`
filter in the workflow. The benchmark README describes the optional diagnostic
kernels and the generated evidence format.
