# Playback progress predecessor indexing — research results

## Decision and scope

Keep the three-line array-index change as a follow-up to
[PR #174](https://github.com/Jagalite/illiquid/pull/174). Against that PR's
dictionary-based worklist, complete progress analysis took **2.8–15.8% less
time on the five synthetic transaction-graph workloads**, and every one of
their 50 paired comparisons favored the candidate.

The bounded real fixtures skip this code path and showed no convincing
benefit. Full exploration plus analysis measured **0.49% slower** in this
cohort. This is a targeted improvement to the playback verifier's
reachability implementation; it does not demonstrate faster playback,
decoding, frame pacing, energy use, or full-application performance.

The PR is stacked on the existing worklist PR so its production diff isolates
the predecessor representation. The parent already supplies the worklist
algorithm and the empty-target/empty-seed fast paths; their benefits are not
attributed to this follow-up.

## Exact experiment

- [Successful Linux run 40733502695](https://github.com/Jagalite/illiquid/actions/runs/40733502695),
  job `122975774924`; benchmark completed at 17:17:56 UTC on 2026-10-28.
- Baseline: `4077f8ad538dd8ed911b38c9b300a98c787c5135`, PR #174's head.
- Measured candidate: `f03f537b7781977695bb64dbbac37b346a8bc27a`.
- Compiler: Swift 6.4.1 release, target `x86_64-unknown-linux-gnu`.
- Host: GitHub-hosted Ubuntu 24.04, image `20261026.354.1`,
  Linux `7.0.0-1017-azure`, four reported logical CPUs.
- Separate optimized production libraries and a separately optimized harness:
  `-O -whole-module-optimization -enable-testing -warnings-as-errors`.
- All production dependencies except the analyzer match the baseline.
  Source snapshots, Git object identities, compiler/binary hashes, commands,
  and timings are retained.
- Kyoto was unavailable. The runner recorded this and used serialized direct
  builds in isolated output directories.

The candidate replaces `[Int: [Int]]` with `[[Int]]`, allocated with one
empty row per state, and changes two subscripts to direct indexing. The
explorer's dense IDs already index `result.nodes`. Fair-edge filtering,
predecessor order, worklist traversal, visited-set updates, all classifications,
and SCC analysis are unchanged. Both implementations retain expected
O(V + E) reachability work.

## All measured results

Times are microseconds per complete operation. Negative changes mean less
elapsed time. Each row contains ten fresh-process serial pairs, balanced
five baseline-first and five candidate-first, with matching calibrated
iteration counts and one warm-up operation per process.

“Δ medians” equals candidate median / baseline median − 1 and matches the
absolute time columns. “Median paired Δ” is the median of the ten within-pair
ratios − 1. The difference between these statistics is retained rather than
selecting the more favorable value.

| Workload | Before µs/op | After µs/op | Δ medians | Median paired Δ | Faster pairs |
| --- | ---: | ---: | ---: | ---: | ---: |
| `real-seek` | 575.11 | 565.51 | -1.67% | -0.08% | 5/10 |
| `real-eof-drain` | 97.52 | 96.97 | -0.56% | -0.57% | 7/10 |
| `real-stop-shutdown` | 278.79 | 279.61 | +0.29% | +0.25% | 4/10 |
| `synthetic-chain-forward` | 519.46 | 476.66 | -8.24% | -8.22% | 10/10 |
| `synthetic-chain-reverse` | 518.99 | 476.34 | -8.22% | -8.30% | 10/10 |
| `synthetic-sparse` | 1723.88 | 1674.87 | -2.84% | -2.64% | 10/10 |
| `synthetic-dense` | 930.69 | 783.63 | -15.80% | -15.76% | 10/10 |
| `synthetic-all-settled` | 1301.20 | 1310.26 | +0.70% | +0.64% | 2/10 |
| `synthetic-no-settled` | 1512.42 | 1511.26 | -0.08% | +0.05% | 5/10 |
| `synthetic-no-fair` | 1505.53 | 1508.49 | +0.20% | +0.05% | 4/10 |
| `synthetic-partial-settled` | 1800.34 | 1685.94 | -6.35% | -6.25% | 10/10 |
| `end-to-end-stop-shutdown` | 40979.12 | 41180.70 | +0.49% | +0.41% | 2/10 |

### Workloads that execute the changed index

The forward and reversed chains each contain 512 fair edges and 513 states.
Both improved by about 8.2%, so the result holds for both tested edge orders.
The dense graph has 257 states and 4,097 fair edges; it improved by 15.8%.

The partial-settlement graph has 2,048 states and 2,047 fair edges: one
transaction can reach a terminal, while the remaining transaction states
are closed. Its 6.35% improvement comes without the additional scans used
by the rejected candidate described below.

The sparse fan-in graph is an explicit counterweight to the array's storage
tradeoff: 2,047 transactions point directly to a single terminal. The array
initializes 2,048 rows while the dictionary needs one destination key. The
whole analyzer nevertheless improved by 2.84% in this bounded fixture.
This does not prove that initialization is harmless for arbitrarily larger
graphs with few fair destinations.

### Real fixtures and controls

| Real fixture | Nodes | Edges | Fair edges | Depth | Transaction states | Cutoff states |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Seek, ready-playing | 573 | 2,049 | 1,290 | 4 | 0 | 377 |
| EOF/drain, playing-av | 69 | 353 | 244 | 4 | 0 | 35 |
| Stop/shutdown, opening | 214 | 1,235 | 699 | 5 | 0 | 87 |

These graphs completed within their configured bounds with zero model
failures. They still contain the listed unmeasured depth-cutoff states.
State/edge caps were 2,000/20,000; wall-clock limits and partial order
reduction were disabled.

All three have zero transaction-classified states. Both variants therefore
skip predecessor construction. Their paired changes were −0.08%, −0.57%,
and +0.25%, with mixed pair outcomes. The seek ratio-of-medians difference
is larger than its paired statistic; it is not evidence of an improvement
in code that the fixture does not execute.

The complete stop/shutdown exploration control took 40.979 ms before and
41.181 ms after: +0.49% by medians, +0.41% paired, and eight of ten pairs
were slower. No end-to-end gain is claimed. The all-settled control was
also slightly slower (+0.70% by medians), although it skips the changed
index. These small control costs remain in the report.

This is one host/toolchain cohort, not a multi-host confidence study.
No outliers were discarded, and timing percentages are not a CI gate.
Min/max observations and every paired ratio are retained.

## Correctness and evidence

Baseline and candidate each passed all **37 state-space tests in debug
and release**: four successful suite executions. Both PR #174's six tests
and this PR's seven additional regressions are retained alongside the
original 24 tests. Additional coverage includes all 512 fair/unfair masks
in both edge orders against an independent forward path oracle, as well
as cutoff/stuck intermediates, seed classifications, cycles, duplicates,
self-loops, and disconnected components.

All **149 complete normalized reports matched exactly** before timing.
Every report field, stuck-state ID, and SCC member is preserved in the
comparison; only unordered SCC representation is normalized. Every timing
pair also matches full graph metadata and ordered graph fingerprints,
timing scope, checksums, and operation counts.

Prepared-graph measurements time the complete production analyzer and a
small result checksum. Construction of the graph, metadata, and serialized
report is outside the interval. The end-to-end workload includes exploration
and analysis. The final cohort has **240 observations across twelve workloads**.

Retained final evidence:

- [All summaries and paired ratios](Evidence/2026-10-28-indexed-linux/summary.json).
- [All raw timing observations](Evidence/2026-10-28-indexed-linux/measurements.csv).
- [Source/compiler/host manifest](Evidence/2026-10-28-indexed-linux/manifest.json).
- [Exact report-comparison receipt](Evidence/2026-10-28-indexed-linux/verification-summary.json).
- [Independent audit](Evidence/2026-10-28-indexed-linux/independent-audit.json).
- [Complete receipts](Evidence/2026-10-28-indexed-linux/receipts.tar.xz),
  163,372 bytes, SHA-256
  `e84a425e613d28666c309c779cd3be0e41837441d4c3e019a9031aa06ef887c8`.

The archive preserves source snapshots, complete reports, all test/build/process
logs, command manifests, calibration, and raw JSON observations. Its
`archive-members.json` records each captured file's size and SHA-256.
The readable CSV retains raw elapsed times and work counts; complete graph
metadata remains in the archive. Binary identities were recorded during CI;
binary bytes are not included.

The tar.xz is a lossless repack of the CI ZIP
(SHA-256 `e51c48c9a0c3a1ec4ead282c9305a80692654dfd27a69704b953ef3972c714f7`).
No captured member content was altered. Extraction uses standard
`tar -xJf receipts.tar.xz`; reproduction commands are in [README.md](README.md).

## Rejected alternative

An earlier candidate kept a first propagation scan, probed for a remaining
frontier, and built a filtered predecessor index only when needed. Its direct
comparison against the same PR #174 baseline passed correctness checks but
slowed the forward chain by 5.18% and the dense graph by 16.12%. Both costs
appeared in all ten pairs. The favorable reversed-chain and partial-settlement
results did not justify those regressions, so that production change was
replaced with the three-line array version.

That [separate run](https://github.com/Jagalite/illiquid/actions/runs/40642533628)
measured candidate `0a9538653be96199777ca7749ef6a73fa24064bb` on Swift 6.4
and an earlier Ubuntu image. Its [summary](Evidence/2026-10-28-rejected-guard-linux/summary.json),
[raw observations](Evidence/2026-10-28-rejected-guard-linux/measurements.csv),
[manifest](Evidence/2026-10-28-rejected-guard-linux/manifest.json), and
[complete receipts](Evidence/2026-10-28-rejected-guard-linux/receipts.tar.xz)
remain available. The archive SHA-256 is
`abad7c39eb5f5bc898fa5deb25e8546334cdf722403d86369b4bcad9e6ddcb5b`.
Each decision uses its own contemporaneous A/B pairs. Absolute times from
the two host/toolchain cohorts must not be combined into a new speedup.

## Remaining qualification and tradeoff

Native macOS qualification is pending and is reported separately from the
successful Linux component experiment. The final documentation/workflow
commits do not change the measured production, test, harness, or runner
source. Full application and live playback testing were not performed.

The index now uses O(V + F) storage for V vertex rows and F fair predecessors,
rather than approximately O(K + F) for K occupied destination keys. It removes
dictionary lookup overhead, but can initialize more empty rows for sparse
destination graphs. Peak memory, allocation counts, and energy use were not
measured; no universal memory reduction is claimed.
