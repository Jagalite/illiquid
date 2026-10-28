# Playback progress reachability benchmark

This experiment measures the complete production progress analyzer used to
qualify the player's deterministic playback state space. It compares current
source with commit `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`.
It measures validation work, not playback rendering or decoding.

## Change under investigation

The original analyzer repeatedly scans every graph edge until the set of
states that can settle stops growing. Its work depends on edge order: a fair
chain whose terminal is encountered last requires one scan per predecessor.

The candidate first checks whether transaction reachability can affect the
report. It skips propagation when there are no transactions or no settled
seeds. It keeps one original forward scan for easy graphs, then probes for a fair edge from an unresolved source into the reached set.
It builds an index of fair predecessors only if that frontier exists and
transactions remain unresolved. Each newly reachable state enters the worklist once.
Classification, SCC analysis, and every report field are preserved.

The fallback's expected time is O(V + E), with hash collections, and it uses
O(V + E) additional temporary storage. The guards avoid constructing the index
for graphs that settle in one pass. The benchmark includes those controls.

## Reproduce

Use matching Swift 6.1-or-newer tools. Native CI uses macOS 26 and Xcode 26.6.
The baseline commit must be present in the checkout's Git history.

```sh
python3 Benchmarks/PlaybackProgressReachability/run.py test --configuration debug --output /tmp/progress-debug
python3 Benchmarks/PlaybackProgressReachability/run.py test --configuration release --output /tmp/progress-release
python3 Benchmarks/PlaybackProgressReachability/run.py benchmark --rounds 10 --target-ms 100 --output /tmp/progress-benchmark
```

Use a fresh output directory for every invocation. The runner snapshots the
actual source bytes before compiling. It uses Kyoto when available and
otherwise records the limitation before serialized direct builds in isolated
output directories. `--swiftc` / `SWIFTC` and `--swift` / `SWIFT`
select a toolchain; `--baseline-ref` explicitly selects another baseline.
The runner supports Linux component research too; results must identify the
platform actually measured.

## Actual sources and timing boundary

Both versions use complete production source. Shared `MediaTrack.swift` and
all `IlliquidPlaybackCore` files form separate optimized libraries. Each
variant builds all `IlliquidPlaybackStateSpace` files into its own optimized
library, then links the same independently optimized harness. Every production
dependency except `PlaybackProgressAnalyzer.swift` must match the pinned
revision. No copied analyzer, platform stub, or inlinable analyzer body is used.

Prepared-graph workloads time the entire production
`PlaybackProgressAnalyzer.analyze` call, including classification, the
reachability calculation, strongly connected components, report construction,
and a small result checksum. Graph construction, metadata, and full report
serialization stay outside these intervals. A separate end-to-end workload
includes both exploration and analysis.

| Workload | Purpose |
| --- | --- |
| `real-seek` | Actual ready-playing seek model, depth 4 |
| `real-eof-drain` | Actual playing-av EOF/drain model, depth 4 |
| `real-stop-shutdown` | Actual opening shutdown model, depth 5 |
| `end-to-end-stop-shutdown` | Complete exploration plus analysis for the same shutdown configuration |
| `synthetic-chain-forward` | 512 fair edges in the repeated scan's unfavorable order |
| `synthetic-chain-reverse` | The same chain in favorable edge order |
| `synthetic-sparse` | 2,047 transactions directly reaching one terminal |
| `synthetic-dense` | 256 cyclic transaction vertices with 16 edges each and a terminal exit |
| `synthetic-all-settled` | 2,048 terminal vertices; reachability cannot change the report |
| `synthetic-no-settled` | 2,048 transactions with no terminal/wait seed |
| `synthetic-partial-settled` | One reachable transaction beside 2,046 closed transaction vertices |
| `synthetic-no-fair` | Unfair exits must not establish fair reachability |

Real fixtures use deterministic limits of 2,000 states and 20,000 edges, with
wall-clock limits disabled. Their actual node/edge counts, cutoff status,
complete search summary, and ordered graph fingerprint accompany every timing.
They are bounded performance fixtures, not complete PR-profile qualification.
Synthetic graphs isolate algorithm behavior and are not substitutes for real
explorer measurements.

The runner starts calibration at one iteration, selects the same iteration
count for each variant, and records pilot observations separately. Final
measurements use fresh serial processes and balanced AB/BA pairs; each performs
one warm-up operation. The standard ten-round run produces 240 final
observations across twelve workloads. Timings have no percentage-based CI gate.

## Correctness and retained evidence

Before timing, both binaries emit 149 complete normalized report receipts:
the twelve timed fixtures, six real models at depth 3, three empty/singleton
cases, and 64 deterministic mixed graphs in both edge orders. Every report
field, stuck-state ID, and SCC member is compared. Only the order of unordered
SCC sets is normalized. Pair validation also requires identical graph metadata,
timing scope, result checksums, and operation counts.

The complete current state-space test suite, including independent reachability
regressions, runs against baseline and candidate in debug and release.
The workflow retains all test logs, production/harness/runner snapshots,
compiler and binary hashes, exact commands, full differential receipts,
calibration, raw measurements, and summaries in a compressed archive.

## Interpretation

Report real analyzer timings separately from synthetic stress cases and from
end-to-end exploration. Graphs without transaction states benefit from skipping
an unused calculation; longer unresolved paths exercise the predecessor
worklist. Any native result describes this host and these bounded fixtures.
This change does not establish faster decoding, higher playback FPS, lower
energy use, or a complete application build.

Measured results and the research decision will be added after native execution.
