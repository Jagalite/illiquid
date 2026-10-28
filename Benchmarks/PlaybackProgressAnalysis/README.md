# Playback progress analysis

Measures the actual playback verifier's progress analyzer and SCC entry point,
using the production graph/core types and explorer. This is verification-tool
performance, not video playback, UI, RSS, or energy measurement.

## Reproduce

With Swift 6.1 or later (including its bundled Testing module), Python 3.10+, and
Git history containing the pinned baseline:

    python3 Benchmarks/PlaybackProgressAnalysis/run.py --output /tmp/progress-analysis

The output directory must be new. Builds use isolated temporary Swift packages;
the full macOS app and native playback targets are outside this component harness.
Follow AGENTS.md and submit the command through Kyoto when that queue is available.

The baseline is the exact analyzer at
ea2ff568237e2667f7b1aeee67b11a44ebe95b72, checked against Git blob
1f6ac16c9cdb5a7ff5dd8063db1e063e842b1c71. The runner stages the production
playback core and state-space modules, with their actual MediaTrack dependency.
It checks that only the analyzer differs between baseline and candidate packages.

Both versions run the current state-space regression suite in debug and release,
including exhaustive three-vertex reachability checks and a complete synthetic
progress-report fixture. The baseline analyzer is also staged under a distinct
enum name in the measured module. Its implementation is otherwise unchanged;
both implementations return the same production report type. Every timed process
checks complete report or component-array equality, including SCC order.

## Workloads and measurements

Each real case constructs the first advertised seed of one of the six production
models at validation depth five. Construction is outside timing, and the graph's
state count, edge count, termination, version, and canonical digest are retained.
Synthetic controls cover empty/isolated graphs, disconnected eight-node cycles,
and a dense graph. They do not represent observed user libraries or playback.

A fresh process handles each case. Within it, baseline and candidate alternate
AB/BA across eight pairs. Calibration selects one shared iteration count to
target 150 ms per sample. Warmup and final exact equality checks are outside
timing; result consumption and replacement of previous iteration results are
included. Wall and process CPU times are recorded separately. No completed
observations are removed.

Use repeated --case arguments to select cases, --pairs for an even pair count,
--target-ms to adjust calibration, or --tests-only for the correctness gates.
Tests and benchmark binaries use Swift 6 language mode and warnings as errors.
All compilation finishes before timing starts.

The artifact contains source hashes, commands, compiler/platform metadata,
debug/release test logs, raw measurements, fixture and calibration receipts, and
median/range/paired-reduction summaries. Timing is informational; correctness and
receipt checks are gates, while a noisy speed threshold is not.
