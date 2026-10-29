# Source visibility root selection

This study compares the source browser's production relative-path lookup and
visibility projection with the single-root matching array removed. The candidate
returns the containment result directly when there is exactly one source root.
Larger root sets use the existing filter/max selection. Input order, Unicode
behavior, and ancestor boundaries stay intact.

The baseline is commit `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`.
The runner reuses the guarded production-source extraction in
`Benchmarks/SourceTreeVisibility/run.py`, verifies that all supporting source
bytes match, and requires the focal excerpt to contain exactly the declared
change. The compiled code is the production matcher and filter.

## Run

Requires macOS or Linux, Swift 6.1 or newer, Python 3.10 or newer, and a Git checkout with
the baseline commit. No native media SDK or external Swift package is required.

Submit builds through Kyoto when it is available, as required by `AGENTS.md`:

```sh
python3 /Volumes/seed1/Projects/kyoto/kyoto.py submit -- \
  python3 Benchmarks/SourceRootSelection/run.py \
  --output /tmp/illiquid-source-root-selection --pairs 8 --target-ms 120
```

On an isolated hosted runner where Kyoto is unavailable, run the Python command
directly. Builds are serialized and use private scratch/module-cache paths.

The output directory must be new or empty. `--tests-only` runs current candidate
regressions in debug/release without historical-source constraints or timings.
Both push and pull-request workflows use this mode, so unrelated source changes
do not invalidate current-source regression coverage. Manual `workflow_dispatch`
runs retain the strict pinned-baseline performance gates; integration drift must
still fail those gates rather than reuse historical performance claims.

## Correctness and measurement

- Baseline release and candidate debug/release run the existing browser-filter,
  visibility-cache, browser-search, and visibility-storage suites, plus golden
  root-selection tests. A nonzero completed Swift Testing count is required.
- Golden cases cover nested roots in every order, exact roots, filesystem root,
  no matches, component boundaries, Unicode bytes, relative regexes, and the
  longest-root boundary for inherited visibility.
- In a full research run, forty-two differential cases compare complete fixture outputs from production
  relative lookup, direct/ancestor evaluation, and visibility projection.
- Timings use fresh baseline/candidate processes in eight alternating AB/BA pairs.
  Each pair has the same iteration count; the faster calibration targets 120 ms.
  Every sample, including regressions and controls, is retained.
- Lookup timings include returned-string consumption. Projection timings include
  the complete `project(rows:configuration:roots:revealsRulePreview:query:)`
  call. Alternating configurations force a visibility rebuild, which is checked
  against the production build counter. Source rows are prepared before timing.
- Empty roots, unmatched roots, exact-root fallback, and projections without
  active rules serve as controls. The no-rule projection bypasses the changed
  lookup.
- Foundation warmup, fixture creation, correctness serialization, and compilation
  are outside the timers. Wall and process CPU clocks cover the same loops.
  Tree construction, sorting, filesystem scans, SwiftUI, and playback are outside
  this experiment.

`manifest.json` records source/excerpt/helper/harness/binary hashes, compiler,
hardware, revisions, and scope. `tests.json`, `verification.json`,
`observations.jsonl`, `summary.json`, and full command/test logs retain the
evidence. CI also prints a compact evidence record for remote inspection.

macOS and Linux runs are recorded separately. The portable run changes only the
POSIX import in MediaSidecarReader and adds FoundationXML to NFOMetadataHints;
both variants receive identical adaptations, recorded with compiled hashes.
Linux measurements do not establish native macOS performance.

## First experiment: lazy filtering (not retained)

The initial `.lazy.filter(...).max(...)` candidate at
`44f9166eac3e22777224590677b04352703dabcc` completed portable validation in
[Actions run 40637901870](https://github.com/Jagalite/illiquid/actions/runs/40637901870/job/122649025893).
All 31 tests passed in baseline release and candidate debug/release; all 39
differential fixtures matched. Eight paired fresh-process samples per workload
used Swift 6.4.1 on Linux x86_64 / AMD EPYC 7763.

The single-root lookup improved by a median paired 13.42%, but the 64-root lookup
regressed by 6.51% (all eight pairs), and the 1,000-row 64-root tree visibility
projection regressed by 4.90% (all eight pairs). This candidate was rejected.
All 208 observations and source/host receipts are retained in
[evidence/linux-lazy-44f9166.json](evidence/linux-lazy-44f9166.json).

## Second experiment: general direct loop (not retained)

The direct-loop candidate at `9d1fd4caed6df925ea81b74f14c17592bb6a1633`
completed [portable validation](https://github.com/Jagalite/illiquid/actions/runs/40639290355/job/122653409035)
with the same 31 tests in each of three configurations and 39 differential cases.
Its own eight-pair cohort improved single-root lookup by 12.35% and nested-root
lookup by 5.77%, but the 64-root tree projection still regressed by 2.08% in every
pair, and the eight-root miss case regressed by 2.28% in every pair. The general
loop was also rejected. See
[evidence/linux-loop-9d1fd4c.json](evidence/linux-loop-9d1fd4c.json) for all 208
observations and receipts. Do not mix its baseline timings with the first run.

## Final candidate: single-root fast path

The final candidate targets the root-count-one case directly. All original
workloads are retained, and a single-root miss case is added to qualify both
outcomes of the new branch (42 differential cases and 224 timed observations).
The final candidate at `de5f1e403c73093fcff986b79173f5b068b90d0b` completed
[portable validation and measurement](https://github.com/Jagalite/illiquid/actions/runs/40639774625/job/122654960640).
All 31 tests passed in baseline release, candidate debug, and candidate release;
all 42 differential cases matched. All 224 timed observations are retained in
[evidence/linux-fast-path-de5f1e4.json](evidence/linux-fast-path-de5f1e4.json).

This cohort ran on an AMD EPYC 9V45 Linux x86_64 runner with Swift 6.4. The earlier
two cohorts used a different host/compiler (AMD EPYC 7763, Swift 6.4.1). Compare
each candidate only to the paired baseline in its own cohort; absolute times
between these experiments cannot be attributed to the implementation change.

### Relative-path lookup

Times are per returned relative path, including consuming its UTF-8 length.

| Workload | Baseline median | Candidate median | Median paired wall reduction | Faster pairs |
| --- | ---: | ---: | ---: | ---: |
| No roots | 218.92 ns | 218.17 ns | 0.75% | 6/8 |
| One matching root | 256.92 ns | 222.29 ns | 13.12% | 8/8 |
| 8 disjoint roots | 664.43 ns | 667.40 ns | -1.39% | 3/8 |
| 64 disjoint roots | 3671.77 ns | 3675.85 ns | 0.38% | 5/8 |
| 8 nested roots | 1420.74 ns | 1425.72 ns | -0.76% | 3/8 |
| 8 Unicode roots | 9332.51 ns | 9360.08 ns | -0.24% | 4/8 |
| 8 roots, no match | 672.50 ns | 667.37 ns | 0.50% | 5/8 |
| One root, no match | 309.13 ns | 298.27 ns | 1.61% | 7/8 |
| One root, exact root path | 210.98 ns | 179.58 ns | 15.24% | 7/8 |

### Visibility projections

Each operation projects 1,000 prepared media rows. The input configurations
alternate so every operation rebuilds visibility; these are neither cached-hit
timings nor full UI timings.

| Workload | Baseline median | Candidate median | Median paired wall reduction | Faster pairs |
| --- | ---: | ---: | ---: | ---: |
| Tree visibility, one root | 1.932 ms | 1.865 ms | 3.32% | 7/8 |
| Files-only visibility, one root | 5.353 ms | 5.230 ms | 3.12% | 7/8 |
| Tree visibility, 64 roots | 5.791 ms | 5.872 ms | -1.30% | 0/8 |
| Files-only visibility, 8 roots | 7.169 ms | 7.298 ms | -0.93% | 1/8 |
| No-rule visibility control | 1.273 ms | 1.256 ms | 0.96% | 6/8 |

Positive reductions are faster; negative values are slower. The paired reduction
is the median of the eight per-pair percentages, not a percentage calculated
from the two separate time medians. CPU results agree closely and are retained
in the raw evidence. The shortest timed sample was
116.25 ms against a 120 ms calibration target.
No samples or outliers were discarded.

### Decision and limits

The matched single-root lookup improved in all eight pairs, with reductions of
9.87–14.97% and a median paired reduction of 13.12%. The single-root tree and
files-only visibility projections improved in seven of eight pairs, by median
paired amounts of 3.32% and 3.12%.

The multi-root results prevent a uniform-speedup claim. The 64-root tree
projection was slower in all eight pairs (median paired regression 1.30%),
and the eight-root files projection was slower in seven pairs (0.93%). The
additional branch could contribute, but this experiment does not isolate its
cost. The no-rule control also moved by roughly 1%, and some workloads have
large pair ranges; see every observation before interpreting small differences.
No workload-frequency data is available to justify an overall weighted speedup.

The candidate is appropriate for a **draft research PR** for the bounded
single-root improvement. Native macOS qualification remains queued, so these
Linux measurements do not establish a production macOS speedup. Full app/UI
latency, filesystem scans, rendering, frame rate, RSS, allocation-byte totals,
and battery use were not measured.

The subsequent test change expands the same golden test functions to exercise
a sole Unicode root, a sole filesystem root, and sole-root exact/descendant/miss
paths. Those assertions are follow-up regression coverage, not part of the
already-recorded `de5f1e4` test execution. The PR's current-source regression
jobs qualify them independently; the measured production implementation and
benchmark harness are unchanged.
