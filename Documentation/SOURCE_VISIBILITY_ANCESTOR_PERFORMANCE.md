# Recursive source visibility: bounded ancestor reuse

## Outcome and qualification

The Linux component experiment supports this optimization. At 10,000 input files,
the median paired wall-time reduction was **65.88% for deep siblings, 42.72% for
groups of 25 siblings, and 39.57% for the real Media-mode projection**. Hidden
ancestor cases improved by 35.31–67.61%. Every pair in these five reuse workloads
was faster at all three measured sizes.

The two zero-hit controls at 10,000 inputs were **1.06% slower for alternating
parents and 0.29% slower for unique parents**. These costs are retained in the
results. The no-rule bypass control had a 2.00% paired median slowdown, while
tree mode was essentially flat (0.01% slower). This is a workload-dependent
improvement, with a deliberately bounded cache, rather than a claim that every
projection is faster.

**Qualification: Linux production components passed. Native macOS component
qualification and the full application build/test gates remain required before
merging.** This experiment did not launch the application or test its UI.

- Baseline: `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`.
- Measured candidate: `dcb0d7b3403d5d66c460e91cb316923eee88f033`.
- [Successful qualification run](https://github.com/Jagalite/illiquid/actions/runs/40640933962),
  job `122658647355`, October 28, 2026.
- Subsequent documentation/evidence commits do not change the measured production
  sources, test source, harness, or qualification workflow.

## Problem and production change

Recursive Files Only and Media projections ask the visibility matcher to evaluate
each file and every ancestor up to its selected source root. Adjacent siblings
repeat identical ancestor URL traversal and regular-expression work.

A mutable value evaluator now belongs to a single visibility projection. It
retains only the most recent non-root parent's ancestor evaluation, keyed by both
parent and selected source root. Exact UTF-8 comparisons prevent canonically
equivalent Swift strings from reusing a regex result for different input bytes.
The immutable matcher snapshot fixes the rules and roots for the evaluator's
lifetime.

Every file still receives its own direct evaluation, including manual and
always-shown overrides. Combining direct and cached ancestor results preserves
ordered regex matches, duplicate direct matches, and nearest-hidden-ancestor
precedence. Cancelled evaluations neither publish nor reuse cached ancestry.
Immediate-root children use the existing root cache. Tree mode keeps its direct
matcher path. Storage is bounded to one parent evaluation and does not grow
with the number of directories; whole-player memory was not measured.

Only two production files change:
`Sources/IlliquidApp/UI/SourcesSidebar.swift` and
`Sources/IlliquidApp/UI/SourceBrowserFilter.swift`.
The immutable uncached matcher remains available for callers and regressions.

## Environment and method

The run used Swift **6.4.1**, Ubuntu 24.04 image **20261026.354.1**,
Linux x86_64, and an AMD EPYC 9V45 host with four available logical CPUs.
Compiler builds were serialized in the isolated checkout, with two compiler
jobs; CI explicitly recorded that Kyoto was unavailable.

Both variants compile actual production projection, matcher, row-building,
sorting, identity, and metadata types into a separate `IlliquidApp` library.
Guarded declaration extraction follows the existing SourceTreeVisibility
harness. Only the matcher/sidebar declaration slice and SourceBrowserFilter
differ; all supporting production snapshots must match byte-for-byte.

The two Linux production adaptations are POSIX and XML imports. One existing
sidecar test receives an explicit directory URL hint. These changes are identical
between variants and are recorded in the source manifests; the repository's
production files are unchanged by staging.

The benchmark times the complete awaited `SourceBrowserFilter.project` call.
It alternates Show Hidden to rebuild visibility while reusing the tree. Fixtures,
URL preparation, metadata recognition, initial tree construction, warmup,
diagnostics, and output receipt computation are outside the timer. Both wall
time and process CPU are recorded. This is a warm tree / rebuilt visibility
measurement.

There are ten workloads, each at 100, 1,000, and 10,000 input files. Six
fresh-process pairs per cell alternate baseline/candidate and candidate/baseline
order. Calibration selects the same even iteration count for both variants.
No sample is discarded, and no control is subtracted. There are **360 timed
observations (180 pairs)**.

Fixtures use synthetic lexical paths and disable sorting so grouped and
interleaved parent order is known. The production default is descending
creation-date sorting. Actual library ordering determines reuse; this study
does not measure a default-library hit rate.

## Complete results

Times below are medians of the six per-process average projection times.
Percentages are `100 × (1 − median(candidate / baseline))` across matched pairs.
A positive reduction is faster; a negative value is slower. A paired percentage
can differ from the ratio of the two independently reported time medians.

| Workload | Input files | Baseline wall ms | Candidate wall ms | Paired wall reduction | Paired CPU reduction |
| --- | ---: | ---: | ---: | ---: | ---: |
| Deep siblings (6 levels) | 100 | 5.417 | 1.886 | +65.21% | +65.22% |
| Groups of 25 siblings (3 levels) | 100 | 2.405 | 1.395 | +41.95% | +41.98% |
| 8 alternating parents (0 hits) | 100 | 2.368 | 2.353 | -0.30% | -0.34% |
| Unique parent per file (0 hits) | 100 | 2.412 | 2.478 | -1.41% | -1.42% |
| Nearest parent hidden | 100 | 2.775 | 1.831 | +35.03% | +35.05% |
| Outermost ancestor hidden | 100 | 5.717 | 1.861 | +67.80% | +67.81% |
| Immediate root children | 100 | 0.803 | 0.791 | +1.68% | +1.81% |
| No visibility rules | 100 | 0.190 | 0.190 | -1.20% | -1.03% |
| Tree mode | 100 | 0.783 | 0.786 | -1.22% | -1.13% |
| Media mode, groups of 100 | 100 | 2.636 | 1.558 | +40.55% | +40.60% |
| Deep siblings (6 levels) | 1,000 | 54.259 | 18.059 | +66.67% | +66.68% |
| Groups of 25 siblings (3 levels) | 1,000 | 24.245 | 13.748 | +43.02% | +43.04% |
| 8 alternating parents (0 hits) | 1,000 | 24.080 | 24.142 | -1.98% | -1.96% |
| Unique parent per file (0 hits) | 1,000 | 25.758 | 26.212 | -1.12% | -1.11% |
| Nearest parent hidden | 1,000 | 28.697 | 18.454 | +35.55% | +35.55% |
| Outermost ancestor hidden | 1,000 | 59.066 | 18.766 | +68.19% | +68.20% |
| Immediate root children | 1,000 | 8.175 | 8.090 | +1.03% | +1.02% |
| No visibility rules | 1,000 | 1.647 | 1.644 | -0.04% | -0.03% |
| Tree mode | 1,000 | 7.449 | 7.445 | +0.04% | +0.05% |
| Media mode, groups of 100 | 1,000 | 26.254 | 15.471 | +41.05% | +41.06% |
| Deep siblings (6 levels) | 10,000 | 559.822 | 192.231 | +65.88% | +65.87% |
| Groups of 25 siblings (3 levels) | 10,000 | 267.726 | 153.067 | +42.72% | +42.71% |
| 8 alternating parents (0 hits) | 10,000 | 250.933 | 252.795 | -1.06% | -1.07% |
| Unique parent per file (0 hits) | 10,000 | 278.567 | 279.988 | -0.29% | -0.30% |
| Nearest parent hidden | 10,000 | 292.489 | 189.064 | +35.31% | +35.31% |
| Outermost ancestor hidden | 10,000 | 598.389 | 193.690 | +67.61% | +67.61% |
| Immediate root children | 10,000 | 88.799 | 87.678 | +0.98% | +0.98% |
| No visibility rules | 10,000 | 18.021 | 18.083 | -2.00% | -1.99% |
| Tree mode | 10,000 | 81.576 | 81.905 | -0.01% | -0.02% |
| Media mode, groups of 100 | 10,000 | 286.528 | 172.584 | +39.57% | +39.57% |

### Observed ranges at 10,000 inputs

These are observed ranges over six pairs, not confidence intervals.

| Workload, 10,000 inputs | Baseline wall range (ms) | Candidate wall range (ms) | Paired candidate / baseline range |
| --- | ---: | ---: | ---: |
| Deep siblings (6 levels) | 556.557–603.854 | 189.230–193.424 | 0.3203–0.3448 |
| Groups of 25 siblings (3 levels) | 265.997–274.326 | 152.521–155.168 | 0.5563–0.5816 |
| 8 alternating parents (0 hits) | 249.295–252.487 | 250.966–253.821 | 0.9955–1.0146 |
| Unique parent per file (0 hits) | 274.158–317.529 | 275.102–280.501 | 0.8815–1.0154 |
| Nearest parent hidden | 290.106–299.197 | 187.841–190.061 | 0.6309–0.6535 |
| Outermost ancestor hidden | 594.092–603.828 | 191.661–228.527 | 0.3184–0.3800 |
| Immediate root children | 87.951–89.462 | 87.242–88.577 | 0.9789–1.0016 |
| No visibility rules | 17.128–18.315 | 17.753–20.507 | 0.9928–1.1197 |
| Tree mode | 80.873–84.169 | 81.195–83.213 | 0.9729–1.0289 |
| Media mode, groups of 100 | 284.312–310.456 | 170.711–181.389 | 0.5499–0.6380 |

The grouped workloads produce 96% cache hits for groups of 25 and 99% for Media
groups of 100; the deep-sibling and hidden-parent workloads have one miss per
projection followed by sibling hits. Alternating and unique-parent workloads
have zero hits. Root children bypass the new cache, while no-rule and tree-mode
controls do not call the ancestor evaluator.

For the 10,000-input no-rule control, independent wall-time medians were
18.021 ms and 18.083 ms, while the paired reduction was −2.00% and pair ratios
ranged from 0.9928 to 1.1197. The differing summaries and spread are visible
rather than being summarized as a proven zero-cost bypass. Across all sizes, the zero-hit controls had median paired overheads of
0.29–1.98%. Individual observations are noisier: retained pair outliers included
27.50% overhead for unique-parent/100 and 21.75% for no-rules/100. Six pairs on one
host do not establish a strict no-regression bound. No statistical significance
claim is made for the small control differences.

## Correctness and evidence audit

All four test runs passed without skipped tests or warnings-as-errors failures:

| Variant | Debug executed | Release executed |
| --- | ---: | ---: |
| Baseline | 16 | 16 |
| Candidate | 24 | 24 |

That is **80 test executions**. All eight added regressions appear in both
candidate JUnit receipts. They cover nearest hidden ancestors, match order,
file overrides and duplicate direct matches, root boundaries and overlapping
roots, canonical Unicode path differences, independent snapshots and value
copies, cancellation, and real projection counts/rule changes.

The runner's qualification gates and an independent audit of the downloaded
receipts confirmed:

- All 360 observations are present, with balanced AB/BA ordering and identical
  per-cell iteration counts.
- All timed baseline/candidate projection receipts match; the repeated two-state
  cycles match across all six pairs.
- All 60 diagnostic records report **one tree build and three visibility builds**,
  and their output receipts match the timed states.
- Every accumulated observation exceeds the 40 ms minimum on both clocks.
  The smallest wall observation was **137.835 ms**; the smallest CPU observation
  was **137.672 ms**.
- All summary medians, ranges, paired ratios, and paired reductions were
  independently recomputed from the raw measurements.
- JUnit hashes match the recorded test receipts; completion records source
  integrity and final executable-hash checks as passed.

Receipts contain a stable complete-field projection digest plus explicit row,
hidden, media-path, thumbnail, and rule counts. They cover ordered row fields,
annotations, metadata, thumbnails, and sorted media paths. They are checksum
parity evidence, not serialized field-by-field traces; the test suites provide
direct semantic assertions.

## Retained evidence and reproduction

The complete original Actions artifact is committed so the evidence survives
Actions retention:

- [Original qualification artifact](../Benchmarks/SourceVisibilityAncestors/evidence/linux-run-40640933962.zip)
  (671,427 bytes; SHA-256
  `24bea16d72ebc9a69700ee85dc9bb4b3ca843c3955355b5e0f4450a44ce0e097`).
- [Full numeric summary](../Benchmarks/SourceVisibilityAncestors/evidence/summary.json),
  [environment](../Benchmarks/SourceVisibilityAncestors/evidence/environment.json),
  [tests](../Benchmarks/SourceVisibilityAncestors/evidence/tests.json),
  [completion](../Benchmarks/SourceVisibilityAncestors/evidence/completion.json), and
  [independent numeric audit](../Benchmarks/SourceVisibilityAncestors/evidence/independent-audit.json).

The ZIP contains raw measurements, calibration pilots, diagnostics, command
stdout/stderr, test text and JUnit XML, complete source manifests, the runner,
and exact staged source packages. Build caches and executable binaries are
excluded; executable SHA-256 hashes are recorded.

```sh
python3 Benchmarks/SourceVisibilityAncestors/run.py \
  --pairs 6 --target-ms 120 --output /tmp/visibility-ancestors
```

Use a new output directory, Swift 6.3.2 or later, Python 3, and a checkout with the
pinned baseline history. Submit through Kyoto when available, per `AGENTS.md`.
See the [benchmark README](../Benchmarks/SourceVisibilityAncestors/README.md) for
staging, exact workloads, and narrower exploratory runs.

## Scope and remaining native gate

These are Linux Foundation measurements of synthetic background source
projections. They establish a component-level improvement for the measured
directory/rule shapes. They do not establish macOS timing, UI typing latency,
frame rate, playback behavior, scanning speed, energy savings, or whole-player
memory effects.

The pull-request workflow schedules the same regression/timing harness on
macOS 26, alongside the repository's full application build and focused native visibility
tests. The existing Source Visibility Storage workflow is triggered by changes to
SourceBrowserFilter.swift and supplies that full-graph build/test gate. Keep the
PR in draft until native qualification completes and any integration failures
are resolved. Recheck this evidence if the production sources or harness change;
a documentation-only commit does not invalidate the measured source hashes.
