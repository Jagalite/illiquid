# Playback progress analysis performance

## Decision and scope

Reuse the outgoing-edge index already built by PlaybackProgressAnalyzer.analyze
when computing strongly connected components. Store discovery indices and
Tarjan-stack membership in arrays indexed by the explorer's dense vertex IDs.

This optimizes the bounded playback verifier's analysis phase. It does not
change the playback state machine, model abstraction, fairness rules, or public
SCC API. The measured operation starts with an already constructed search
result and includes all of analyze's own graph preparation and classification.

## Why this area

At baseline ea2ff568237e2667f7b1aeee67b11a44ebe95b72, analyze groups edges by
source for classification and closed-component checks. Its SCC call groups the
same complete edge values again and maps those groups into integer successor
arrays. That second representation is transient and unnecessary for the
analyzer, which already retains the first one.

The selected implementation passes the first index to a private SCC overload.
The public edges-based overload retains its interface and builds an index for
direct callers. Vertex and successor visitation order remain the same.
Nonnegative discovery indices permit -1 to represent an unseen vertex; dense
vertex IDs permit a Boolean array to represent stack membership. Complexity
remains O(V + E).

A reverse-worklist replacement for the fair-reachability fixed point was
considered but not selected. Existing effects classify many intermediate
states as declared external waits before transaction classification, so long
model paths do not establish repeated fixed-point scans. This experiment keeps
that code unchanged and isolates graph/index storage.

## Correctness

Both the baseline and candidate run the current playback state-space tests in
debug and release, with Swift 6 mode and warnings as errors. Added tests cover:

- All 512 directed three-vertex graphs, in forward and reversed edge order,
  against an independent mutual-reachability oracle.
- Exact component-array order for cycles, parallel edges, self-loops, and
  disconnected vertices.
- Edges into already completed components, empty graphs, and a 128-vertex cycle.
- An exact complete progress report combining terminal/stable/external waits,
  cutoff precedence, fair and nonfair edges, stuck states, and obligation ranks.

Every measured process additionally compares full reports and component arrays
against the exact pinned analyzer, staged under a different enum name. Report
equality includes component order, not only component counts.

## Measurement protocol

A fresh process handles each case. Production cases construct the first
advertised seed of all six models at validation depth five, outside timing.
The receipts record actual graph sizes, model versions, seed identities,
termination, and canonical digests. The analyzer and the public SCC entry
point are measured separately on the same kinds of production graphs.

Within each process, eight paired samples alternate baseline/candidate and
candidate/baseline order. Both use the same calibrated iteration count.
Warmup, oracle comparisons, and final checks occur outside timing; the timed
loop includes result consumption and replacement of prior results. Wall and
process CPU samples are retained without outlier removal.

Synthetic empty, isolated, disconnected-cycle, and dense graphs are controls,
reported separately from production explorer graphs. These controls do not
represent native media workloads.

## Results: Linux, Swift 6.4

[The Linux job passed](https://github.com/Jagalite/illiquid/actions/runs/40639740562/job/122654847304)
on the hosted x86_64 Linux runner using Swift 6.4. These results apply to the
measured analyzer phase on that platform. The macOS job was still queued when
this report was written; no macOS performance result is claimed.

Complete analysis of production explorer graphs:

| Model | States / edges | Baseline median | Candidate median | Median paired reduction |
| --- | ---: | ---: | ---: | ---: |
| seek | 1,223 / 5,343 | 1.5796 ms | 1.0377 ms | 34.3% |
| eof-drain | 104 / 703 | 0.2006 ms | 0.1387 ms | 30.6% |
| recovery | 11 / 27 | 0.0115 ms | 0.0083 ms | 27.7% |
| track-subtitles | 172 / 666 | 0.1946 ms | 0.1315 ms | 32.5% |
| stop-shutdown | 214 / 1,235 | 0.3118 ms | 0.1761 ms | 43.6% |
| preroll-buffering | 137 / 677 | 0.1666 ms | 0.1066 ms | 36.0% |

All six graphs completed within the configured depth-five bounds; none hit a
state, edge, or time cap. The bounded graphs still contain depth-boundary cutoff
states, so this is not an unbounded state-space completeness claim. All eight pairs favored the candidate in every case. Process CPU
reductions closely tracked the wall-time reductions. The largest measured graph
in this cohort has 1,223 states and 5,343 edges; larger qualification profiles
were not measured.

The whole-analyzer paired median reduction is **27.7–43.6%**. In absolute terms,
the seek graph improved from about **1.580 ms to 1.038 ms** per analysis.
This is not an estimate of the total verifier run-time reduction: exploration
and canonicalization are outside the timed region.

The public SCC entry point also improved:

| Graph | Fixture | Baseline median | Candidate median | Median paired reduction |
| --- | --- | ---: | ---: | ---: |
| seek | Production graph | 0.730766 ms | 0.542783 ms | 25.7% |
| eof-drain | Production graph | 0.070638 ms | 0.055145 ms | 22.4% |
| recovery | Production graph | 0.004934 ms | 0.003672 ms | 25.5% |
| track-subtitles | Production graph | 0.090725 ms | 0.068151 ms | 24.9% |
| stop-shutdown | Production graph | 0.151947 ms | 0.107496 ms | 29.2% |
| preroll-buffering | Production graph | 0.077735 ms | 0.058531 ms | 24.6% |
| empty | Synthetic control | 0.000082 ms | 0.000034 ms | 58.5% |
| isolated | Synthetic control | 0.586586 ms | 0.485296 ms | 17.3% |
| cycles | Synthetic control | 1.981087 ms | 1.253628 ms | 36.8% |
| dense | Synthetic control | 4.265201 ms | 2.058116 ms | 51.7% |

The empty-graph control is below a tenth of a microsecond, reaches the
100,000-iteration calibration ceiling, and is not a representative headline
result. All eight pairs favored the candidate in the
other controls as well. No numerical heap or allocation claim is made.

### Completed gates

- 29 tests passed for baseline debug, baseline release, candidate debug, and
  candidate release (116 test executions).
- 16 workloads produced all 256 expected timing observations.
- Full output equality, complete coverage, and actual AB/BA order checks passed.
- Every production fixture reported zero stuck states and closed nonterminal
  components, and identical report contents between implementations.

### Retained evidence

[linux.json](../Benchmarks/PlaybackProgressAnalysis/evidence/linux.json) preserves
the original structured job-log receipts: environment/source/binary identities,
test counts, fixtures, calibration, all raw measurements, summaries, completion,
and the run/job provenance. The workflow artifact contains the original logs
and command/source receipts. The measured candidate commit is
`c2565bcd1c9a6d0f1161f74b57d3ce7826099712`; the production analyzer SHA-256 is
`c467d083d33d42553736e08d611788c3c25e304874b4c42dfa624569ab312028`.

## Evidence and limits

The runner retains source, compiler, executable and harness identities; command
logs; debug/release test receipts; graph fixtures; calibration; all raw samples;
and summaries. A completion receipt verifies full matrix coverage, exact parity,
and balanced order. The workflow also uploads the raw artifact.

These are component timings from one hosted Linux x86_64 runner using Swift 6.4.
Native macOS qualification remains pending. They do not establish
end-to-end exploration speed, player responsiveness, decoding throughput,
resident memory, or energy improvement. The recursive Tarjan implementation and
its stack-depth limit are retained.
