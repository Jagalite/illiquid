# Elastic control-bar geometry performance research

## Question and scope

Can the player reduce computation during control-bar hovering, drawing and dragging by evaluating straight geometry directly? The candidate changes one geometry function. Its adoption depends on reproducible timing gains and acceptable results for partially bent controls.

The [control-bar host](../Sources/IlliquidApp/UI/PlaybackControlBarHost.swift) selects the elastic bar by default. In [ElasticPlaybackControlBar.swift](../Sources/IlliquidApp/UI/ElasticPlaybackControlBar.swift), several frequently used operations converge on `rawPoint(at:)`:

| Caller | Work before the change |
| --- | --- |
| Geometry construction | Integrates 145 surface points, then computes utility positions. |
| Timeline hit testing | Integrates 121 track points per `timelineFraction` query. |
| Surface hit testing | Integrates 161 surface points per `surfaceFraction` query. |
| Continuous hover | Calls both timeline and surface hit testing: up to 282 point integrations per event. |
| Timeline artwork | Builds 64-point track, progress and optional buffer paths, plus marker positions. |
| Drag tracking | Repeatedly constructs geometry while solving for the grabbed point. |

Each point previously required `ceil(abs(s) / 6)` midpoint integration steps, evaluating sine and cosine of the tangent. A 470-point displacement takes 79 steps. Hovering over a straight control therefore repeats numerical integration even though its direction is constant. These counts follow the source; they are not measurements of whole-player CPU use.

## Candidate and constant-angle proof

The candidate retains the zero-distance return and adds an exact gate for `bendProgress == 0 || bendProgress == 1`. It evaluates the displacement as:

```swift
let angle = tangentAngle(at: 0)
return CGPoint(
    x: center.x + cos(angle) * s,
    y: center.y + sin(angle) * s
)
```

At progress zero, `tangentAngle` returns the orientation angle at every position. At progress one, clamped outwardness puts the propagation threshold in `[0, 0.92]`. The turn span is `1 - 0.92`, so `(1 - threshold) / turnSpan` is at least one. Clamping produces local progress one everywhere, and the tangent is the completed quarter-turn angle everywhere. Both cases describe a straight line.

Calling the existing tangent function preserves its signed angle convention. Every partial bend, however close to an endpoint, retains the original midpoint integration. Sampling counts, containment, interpolation and hit-test bounds retain their existing definitions. The candidate adds no retained geometry data.

Multiplication and repeated addition can round differently. Correctness therefore requires bounded numerical differences and interaction checks, rather than identical floating-point bits. An unchanged integration loop also does not guarantee unchanged runtime: the extra branch or compiler decisions can affect partially bent controls, which are explicit comparison scenarios.

## Reproduction and measurement

[run.py](../Benchmarks/ElasticControlGeometry/run.py) extracts the actual production geometry and tests. It reconstructs the original implementation using the retained `rawPoint` fixture and verifies the complete baseline geometry against the hash pinned to revision `8c3cc3d4008d5d1b8d436bcf2d51d891382b6548` in [baseline.json](../Benchmarks/ElasticControlGeometry/baseline.json).

```sh
python3 Benchmarks/ElasticControlGeometry/run.py \
  --output /tmp/elastic-geometry-results --rounds 6 --iterations 4000
python3 Benchmarks/ElasticControlGeometry/verify.py /tmp/elastic-geometry-results
```

Use a new output directory and an available Swift toolchain. The runner tests both implementations in debug and release, then builds optimized benchmarks with whole-module optimization. [Benchmark.swift](../Benchmarks/ElasticControlGeometry/Benchmark.swift) exercises construction, combined hover queries, three path constructions and iterative drag tracking. Its 13 scenarios include straight, rotated, completed-turn, slightly bent and substantially curved controls.

Each timed process performs 32 warm-up operations before measurement, varies inputs and emits a consumed checksum. Baseline/candidate order alternates between rounds; timed processes run sequentially. Receipts retain wall time, process CPU time, commands, compiler/platform details, source and executable hashes. Summaries use per-operation wall-time medians. [verify.py](../Benchmarks/ElasticControlGeometry/verify.py) independently checks saved binaries and generated sources, process-output correspondence, complete pairs, ordering and recomputed medians.

## Correctness coverage

The runner includes existing placement, sidebar, geometry and timeline precision tests, plus [focused regression tests](../Tests/IlliquidAppTests/ElasticGeometryPerformanceRegressionTests.swift). Coverage includes all four orientations, both contacted sides, both bend directions, compact and large layouts, containment, positive/negative displacement, integration-step boundaries and transitions into bending.

[Differential.swift](../Benchmarks/ElasticControlGeometry/Differential.swift) compares baseline and candidate coordinates, projected timeline fractions, surface samples, utility positions, sidebar avoidance and iterative drag tracking. Its expanded matrix includes extreme requested centers and both sides of bend completion. Numerical comparisons require differences no larger than `1e-8` points/fraction units.

Hit classifications and nearest-sample choices must agree `1e-6` points to either side of their boundaries. Exact distance cutoffs and equidistant samples can resolve differently after rounding; the harness counts those cases separately and checks that the stored local offset preserves the grabbed point. Existing inclusive-boundary tests also run.

## Linux component results

**The endpoint optimization merits a PR.** The retained Linux study used Swift 6.3.2 in an x86_64 environment reporting an AMD EPYC 9V74 processor. Six AB/BA rounds covered 13 scenarios, with 4,000 iterations per observation (400 drag corrections): **156 separately timed processes**. The independent verifier matched all observations to process output and verified four executable hashes and 15 generated source hashes. [Raw measurements, ranges, environment and receipts](../Benchmarks/ElasticControlGeometry/evidence/linux/).

| Workload | Original median (µs) | Candidate median (µs) | Time change |
| --- | ---: | ---: | ---: |
| Straight: construct geometry | 95.52 | 4.73 | -95.05% |
| Straight: hover hit testing | 150.66 | 5.75 | -96.18% |
| Rotated straight: hover | 124.58 | 7.27 | -94.17% |
| Straight: three paths | 106.00 | 5.63 | -94.69% |
| Straight: drag correction | 1742.72 | 68.80 | -96.05% |
| Fully turned: construct geometry | 96.99 | 5.83 | -93.99% |
| Fully turned: hover | 157.93 | 10.38 | -93.43% |
| Fully turned: three paths | 105.16 | 7.48 | -92.89% |
| Partial bend: construct geometry | 114.42 | 117.23 | +2.46% |
| Partial bend: hover | 166.23 | 166.66 | +0.26% |
| Partial bend: three paths | 104.64 | 105.88 | +1.18% |
| Partial bend: drag correction | 1958.56 | 2045.17 | +4.42% |
| Slight bend: hover | 175.39 | 184.17 | +5.00% |

Straight and fully turned cases improve 14.1–26.2×. The straight drag solver falls from 1.743 ms to 0.069 ms per correction, saving about 1.674 ms of this component's work. Partial-bend medians range from 0.26% to 5.00% slower: slightly bent hover adds 8.77 µs and partial-bend drag correction adds 86.62 µs. Process CPU measurements show a similar direction; these costs must not be described as zero regression. The small additional cost in partial bends is acceptable for this candidate given the large reduction in ordinary straight-bar work, but whole-app impact depends on layout and interaction frequency.

An earlier short pilot suggested larger curved regressions and prompted this longer comparison. Its incomplete append receipt was rejected; final measurements were saved atomically and independently read back before acceptance. A stricter early differential assertion also assumed identical bend-progress bits after sidebar avoidance; the final oracle correctly compares numerically derived centers while retaining exact progress equality for identical constructor inputs. Neither issue required a production-code change.

### Correctness

The test run passed 37 extracted tests in each baseline/candidate debug/release configuration. The expanded differential covered 1,184 geometries and 520,774 numeric comparisons. Maximum coordinate error was `4.092726157978177e-11` points and maximum fraction error `5.97597736269953e-14`; partial bends constructed from identical inputs had exactly zero error.

Of 3,552 boundary classifications, 16 differed exactly at the cutoff; all checks `1e-6` points to either side agreed. Of 21,312 nearest-sample checks, 1,464 exact midpoint ties selected the other adjacent sample. Off-tie choices agreed, and reconstructed grabbed points matched within the numerical tolerance. These are disclosed rounding differences, not bit-identical behavior.

## Native macOS qualification

**Native qualification passed.** The [geometry workflow](https://github.com/Jagalite/illiquid/actions/runs/39043693976) ran the same six-round, 156-process study with real `SwiftUI.Path`, Apple Swift 6.3.3 and macOS 26.6.2 ARM64. It tested candidate commit `c7631714fba0c579e40f352edc44a35a7056f7eb` merged with the pinned baseline as `1f0e9796c6f56f70b80278dfbd3ace6fa46f4dfa`. Downloaded artifact bytes matched GitHub's SHA-256 digest, and an independent local readback verified all observations, four binaries and 15 generated sources. [Retained native evidence](../Benchmarks/ElasticControlGeometry/evidence/macos/).

| Workload | Original median (µs) | Candidate median (µs) | Time change |
| --- | ---: | ---: | ---: |
| Straight: construct geometry | 13.32 | 2.76 | -79.27% |
| Straight: hover hit testing | 18.11 | 3.55 | -80.41% |
| Rotated straight: hover | 39.65 | 3.99 | -89.95% |
| Straight: three paths | 24.14 | 13.09 | -45.77% |
| Straight: drag correction | 222.53 | 34.65 | -84.43% |
| Fully turned: construct geometry | 57.75 | 4.30 | -92.56% |
| Fully turned: hover | 88.03 | 6.04 | -93.14% |
| Fully turned: three paths | 69.08 | 14.90 | -78.43% |
| Partial bend: construct geometry | 42.40 | 42.68 | +0.68% |
| Partial bend: hover | 57.15 | 57.61 | +0.81% |
| Partial bend: three paths | 42.30 | 42.75 | +1.07% |
| Partial bend: drag correction | 781.36 | 776.66 | -0.60% |
| Slight bend: hover | 50.22 | 50.65 | +0.87% |

Native endpoint workloads improve 1.84–14.58×, including the real path-construction cost. Straight hover improves 5.11× and straight drag correction 6.42×, saving 187.88 µs per correction. Native path results improve less than the Linux collector results; real path construction remains part of the timed work. Partial-bend medians range from 0.60% faster to 1.07% slower, with overlapping observed ranges. The largest positive absolute median change among those controls is 0.46 µs. Process CPU medians show the same direction for all scenarios. These small control differences should not be treated as a precisely established causal regression or as proof of zero cost.

All 37 extracted tests passed in each native baseline/candidate debug/release configuration. Both native differential builds passed the same 520,774 comparisons and reported the same maximum coordinate/fraction errors as Linux. Native exact-cutoff differences numbered 17 rather than 16; all checks on either side of the cutoff agreed, and the 1,464 exact sample ties retained their reconstructed initial grab position.

Separately, the [native application job](https://github.com/Jagalite/illiquid/actions/runs/39043694015/job/117428090101) built the real app dependency graph and passed 92 tests in 12 suites, including placement, geometry, timeline and the new fast-path regression suite. The [focused core job](https://github.com/Jagalite/illiquid/actions/runs/39043694015/job/117428090325) passed 14 Swift tests and eight Python qualification tests. The [existing non-decoding workflow](https://github.com/Jagalite/illiquid/actions/runs/39043693924) also passed. Native timing evidence supports the endpoint change, while whole-player user-visible impact remains unmeasured.

## Limits and alternatives

On macOS, the harness uses `SwiftUI.Path`. On Linux, [PathSupport.swift](../Benchmarks/ElasticControlGeometry/PathSupport.swift) supplies a point collector. Linux path timings therefore measure geometry and that collector, not native SwiftUI drawing. Even native harness timings do not measure video playback, event-to-display latency, GPU work, memory residency or battery use.

Caching hit-test samples could accelerate curved controls but adds retained arrays and construction work. Partial-bend plateau detection could avoid more integration, but requires additional progress calculations and rounding review; equal rounded endpoint angles alone are insufficient justification. Neither alternative is implemented in this candidate.
