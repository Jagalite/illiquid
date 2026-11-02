# Playback progress reachability research

This experiment measures `PlaybackProgressAnalyzer.analyze`, the bounded playback verifier's progress analysis. It does not measure decoding, rendering, UI responsiveness, or player frame rate.

## Problem and change

The analyzer classifies graph nodes, finds which transactions can reach a settled state using fair edges, and reports closed nonterminal strongly connected components. Previously, reachability repeatedly scanned every edge until a pass added no nodes. A forward-ordered chain needs one pass per predecessor.

The candidate builds fair predecessor lists and visits each reachable node once with a worklist. Terminal states, stable intentional waits, and declared external waits remain the seeds. Unmeasured cutoff nodes remain traversable intermediates without becoming seeds. The classification rules, obligation ranks, SCC algorithm, and report ordering are unchanged.

The candidate also skips reachability when no transactions need classification or no settled seeds exist. Reachability only contributes to the settled-transaction count, so these results are already known.

The reachability phase changes from worst-case O(VE) to expected O(V + E). It adds O(V + E_fair) transient memory for the worklist and reverse edges; that storage leaves scope before SCC analysis. Peak process memory has not been measured.

## Method

The baseline analyzer is pinned to `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`. Both variants compile the same current production support, tests, and benchmark harness. Only the analyzer is replaced with the baseline version. Source and executable SHA-256 hashes are recorded. The initial run's support files are unchanged from the pinned revision.

The harness compiles in a separate optimized Swift module. `-enable-testing` on the state-space module permits fixture construction through existing internal initializers in both variants; production APIs and source files are not rewritten. The isolated package uses the actual playback-core and state-space sources plus their sole IlliquidCore dependency, `MediaTrack.swift`.

Six workloads build real explorer graphs, one for each model, before the timer. Time budgets are disabled. Complete progress analysis is timed, including its allocations, classification, reachability, SCC work, report construction, and result consumption. Graph construction, search, canonicalization, parity checking, and JSON encoding are outside timing.

Seven explicitly synthetic workloads cover long forward-ordered chains, a wide layered graph, an unfair bridge and unreachable cycle, no transactions, and no settled seeds. The 4,096-edge chain is a scaling stress case, not a claim about ordinary reachable playback search depth.

Every workload first passes exact baseline/candidate JSON parity for its summary, complete ordered graph, every normalized node, predecessors, failures, and progress report. Known Set fields are normalized for serialization; ordered arrays retain their order. Synthetic reports additionally match independent expected values.

Each timing sample runs in a fresh process with one untimed warmup. Six balanced AB/BA pairs use equal iteration counts per pair. Calibration targets 250 ms for the faster variant, capped at approximately two seconds for the slower variant and 1,000,000 iterations. Extreme speed differences can therefore produce faster samples below 250 ms; raw durations are retained. No timing threshold is imposed on noisy hosted CI.

## Correctness

The same regression suites run against baseline release, candidate debug, and candidate release. The new tests use synchronous fixed-point reachability and a transitive-closure SCC oracle, covering empty/unseeded/fully settled graphs, all seed classes, cutoff intermediates, unfair edges, cycles, duplicates, self-loops, edge permutations, and 96 deterministic small graphs.

This qualifies the isolated playback-core/state-space components. A full app build and live UI/playback checks are outside this experiment.

## Reproduce

When Kyoto is available, preserve the command and submit it through the shared queue:

```sh
python3 /Volumes/seed1/Projects/kyoto/kyoto.py submit -- \
  python3 Benchmarks/StateSpaceProgress/run.py \
  --output /tmp/illiquid-progress-evidence --pairs 6 --min-seconds 0.25
```

Inspect the queue's job status and logs before claiming execution. On an isolated machine without Kyoto, explain that limitation and run the same Python command directly. Use a fresh empty output directory. The script builds and tests serially in separate temporary packages.

The workflow runs on macOS using the repository's pinned Xcode selection and on Ubuntu with its installed Swift compiler. It archives source/binary receipts, command logs, complete verification output, raw paired observations, and summaries.

## Recorded results: Linux x86_64

[Successful job 122653349767](https://github.com/Jagalite/illiquid/actions/runs/40639271897/job/122653349767) measured commit `2de8aed551071d4bba0e3275bc4e3331100d281b` on 2026-10-28. The compiler was Swift 6.4 (`swift-6.4-RELEASE`), target `x86_64-unknown-linux-gnu`; the host was `Linux-6.17.0-1022-azure-x86_64-with-glibc2.39`. These are portable Swift component measurements. macOS qualification was still queued when this evidence was recorded.

All **82 tests in 8 suites** passed in each of baseline release, candidate debug, and candidate release. All **13 complete verification receipts** matched, including their serialized SHA-256 hashes. Only the analyzer's production source hash differed. The run collected **78 paired comparisons / 156 fresh-process timing samples**.

### Graphs generated by the explorer

| Workload | States / edges | Baseline ms | Candidate ms | Median time reduction | Faster pairs |
| --- | ---: | ---: | ---: | ---: | ---: |
| Seek | 573 / 2,049 | 0.6072 | 0.5986 | 1.4% | 4/6 |
| EOF/drain | 71 / 341 | 0.1093 | 0.1070 | 2.1% | 6/6 |
| Recovery | 342 / 1,164 | 0.3755 | 0.3579 | 4.7% | 6/6 |
| Tracks/subtitles | 78 / 284 | 0.0797 | 0.0776 | 2.6% | 5/6 |
| Stop/shutdown | 127 / 574 | 0.1489 | 0.1413 | 5.1% | 6/6 |
| Preroll/buffering | 34 / 183 | 0.0429 | 0.0403 | 6.0% | 6/6 |

Every one of these bounded depth-4 graphs had zero transaction states. Their improvements exercise the no-transaction fast path; they do **not** measure reverse-worklist traversal. Seek's 1.4% median difference overlaps the observed noise (only four of six pairs improved). Tracks/subtitles improved in five pairs; EOF/drain, recovery, stop/shutdown, and preroll/buffering improved in all six. These sub-millisecond absolute times should not be presented as a perceptible playback improvement.

### Synthetic scaling and controls

| Workload | States / edges | Baseline ms | Candidate ms | Median time reduction | Faster pairs |
| --- | ---: | ---: | ---: | ---: | ---: |
| Synthetic chain, 256 edges | 257 / 256 | 1.4756 | 0.2824 | 80.9% | 6/6 |
| Synthetic chain, 1,024 edges | 1,025 / 1,024 | 19.9007 | 1.1388 | 94.3% | 6/6 |
| Synthetic chain, 4,096 edges | 4,097 / 4,096 | 311.3540 | 4.8648 | 98.4% | 6/6 |
| Synthetic layered graph, 64 × 32 | 2,049 / 4,032 | 4.8648 | 2.6449 | 45.6% | 6/6 |
| Unfair-bridge control | 131 / 130 | 0.2459 | 0.1408 | 42.7% | 6/6 |
| All-settled control | 256 / 255 | 0.1985 | 0.1944 | 2.0% | 6/6 |
| No-settled-seed control | 256 / 256 | 0.1906 | 0.1895 | 0.5% | 3/6 |

The 4,096-edge chain improves from 311.3540 ms to 4.8648 ms: **64.0×** by the ratio of median times. The 64 × 32 layered graph improves by **1.84×**. Every paired sample improved in the chain, layered, and unfair-bridge workloads. These fixtures deliberately exercise transactions and fair-path propagation; the long chain is a worst-order scaling demonstration.

The no-settled-seed control is effectively unchanged: its median differs by 0.5%, but only three of six pairs improve and the paired median speedup is approximately 1.00×. No claim of a reliable gain is made for that control.

The initial portable results support the optimization without establishing macOS timings, end-to-end explorer speed, player responsiveness, frame rate, energy use, or peak-memory improvement.

### Retained evidence

The compact machine-readable evidence is under [PerformanceEvidence/StateSpaceProgress/linux](PerformanceEvidence/StateSpaceProgress/linux):

- [manifest.json](PerformanceEvidence/StateSpaceProgress/linux/manifest.json): exact sources, harnesses, executables, toolchain, and host.
- [verification.json](PerformanceEvidence/StateSpaceProgress/linux/verification.json): every comparison outcome, summary, report, and full-receipt hash.
- [observations.json](PerformanceEvidence/StateSpaceProgress/linux/observations.json): every raw paired timing receipt, including actual sample durations.
- [summary.json](PerformanceEvidence/StateSpaceProgress/linux/summary.json): medians, ranges, and per-pair ratios.
- [tests.json](PerformanceEvidence/StateSpaceProgress/linux/tests.json) and [receipt.json](PerformanceEvidence/StateSpaceProgress/linux/receipt.json): test configurations and execution provenance.

The workflow artifact `state-space-progress-evidence-linux` retains the complete graph receipts and command/stdout/stderr logs for 30 days. The committed source and benchmark reproduce the experiment after that artifact expires.
