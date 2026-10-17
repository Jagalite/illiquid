# Elastic control-bar geometry experiment

This experiment measures the geometry used by the default elastic playback bar.
The candidate evaluates a constant tangent directly when bend progress is exactly
zero or one. Partial bends retain the original midpoint integration.

## Reproduce

With Swift available on `PATH`, from the repository root:

```sh
python3 Benchmarks/ElasticControlGeometry/run.py --output /tmp/elastic-geometry --rounds 6 --iterations 4000
python3 Benchmarks/ElasticControlGeometry/verify.py /tmp/elastic-geometry
```

Use a new, empty output directory for each run. `--tests-only` runs the four
debug/release baseline/candidate test configurations and both differential builds
without timings. The tests use the toolchain's bundled Swift Testing library and
do not resolve the full application's dependencies. The focused source package is
temporary and does not alter `Package.swift`.

On macOS 26, extracted geometry uses the real `SwiftUI.Path`. On Linux, the path
builder uses `PathSupport.swift`, a Foundation point collector. Linux path results
measure the sampled geometry and that collector; they do not measure native path
creation or drawing. No variant opens media, decodes video, creates a window, or
measures whole-player CPU, memory, energy, or input-to-screen latency.

## Source and correctness controls

- The baseline `rawPoint` function is copied from main revision
  `8c3cc3d4008d5d1b8d436bcf2d51d891382b6548`. `baseline.json` records the original
  file's Git blob and SHA-256 hashes of the function and geometry excerpt.
- The runner extracts the current geometry declarations verbatim, substitutes only
  that original function for the baseline, and checks the reconstructed geometry
  against its pinned hash. The two timed builds use the same callers and data.
- The focused package runs the existing placement, geometry, and timeline suites,
  plus `ElasticGeometryPerformanceRegressionTests` from the application tests.
- `Differential.swift` compares both implementations on identical inputs, then
  compares derived sidebar placements and iterative drag corrections. It measures
  coordinate/fraction errors and tests both sides of hit boundaries and nearest
  sample ties. Exactly equidistant samples may change their last-bit tie winner;
  the grabbed point must still match. No hit threshold is widened in production.

## Timing protocol

Thirteen scenarios cover construction, hover hit testing, three timeline paths,
and iterative drag tracking. They include straight, rotated straight, fully
turned, partially bent, and slightly bent bars. A hover uses the production
16-point track threshold and 28-point surface threshold. Tracking calls the actual
18-iteration correction solver. The paths workload includes three sampled paths,
their bounds, and a moving knob; it excludes Canvas rendering.

Each observation starts a fresh optimized Swift process, warms the scenario
outside the timing window, uses changing inputs, and consumes the results in a
checksum. The two variants run sequentially in AB/BA order alternating by round.
Tracking uses one tenth as many iterations because each operation constructs many
geometries. Both wall and process CPU time are recorded. Summaries report median
wall time per operation, ranges, and the ratio of variant medians. There is no
flaky performance threshold in CI.

The output includes all process commands/stdout/stderr, raw measurements,
compiler/platform information, generated sources, source/binary hashes,
differential results, test logs, and summary statistics. The verifier requires
complete paired observations, matches each row to the timed process output, and
recomputes medians. A missing run, mismatched command, changed binary/source, or
inconsistent summary fails verification. The runner also rejects harness edits
made while an experiment is running.

The [research report](../../Documentation/ELASTIC_CONTROL_GEOMETRY_RESEARCH.md)
contains the retained results and their interpretation. Native application
compilation and the same application test suites run separately in the existing
restoration workflow; component timings are not a substitute for that check.
