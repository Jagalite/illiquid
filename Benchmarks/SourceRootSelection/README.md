# Source visibility root selection

This study compares the source browser's production relative-path lookup and
visibility projection with the eager matching-root array removed. The candidate
uses one explicit pass to retain the first longest match; containment,
character-count comparison, input order, Unicode behavior, and ancestor
boundaries stay intact.

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
This is the pull-request workflow mode, so future unrelated source changes do
not invalidate the frozen research baseline.

## Correctness and measurement

- Baseline release and candidate debug/release run the existing browser-filter,
  visibility-cache, browser-search, and visibility-storage suites, plus golden
  root-selection tests. A nonzero completed Swift Testing count is required.
- Golden cases cover nested roots in every order, exact roots, filesystem root,
  no matches, component boundaries, Unicode bytes, relative regexes, and the
  longest-root boundary for inherited visibility.
- In a full research run, thirty-nine differential cases compare complete fixture outputs from production
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

The explicit-loop follow-up is pending measurement against the same baseline
and workload matrix. Native macOS performance remains unqualified. No measured
allocation-byte, whole-player memory, frame-rate, or battery claim is made.
