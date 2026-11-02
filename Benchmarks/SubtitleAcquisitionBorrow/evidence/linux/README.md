# Linux qualification evidence

Measured on 2026-10-28 against main
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`. The candidate was a dirty worktree;
`build-receipt.json` identifies every full production source and extracted
source by SHA-256. The source files in this PR match those measured hashes.

## Results and receipts

- [CPU and wall-time summaries](summary.json): eight workloads, six balanced
  fresh-process pairs per workload, 96 accepted observations. Includes medians,
  ranges, all paired ratios, and duration-floor checks.
- [Timing observations](measurements.jsonl): all 96 numeric observations,
  iteration counts, packet sizes, checksums, and fixed workload/variant labels.
- [Allocation summaries](allocation-summary.json) and
  [allocation observations](allocation-measurements.jsonl): 48 separate
  observations, three per variant/workload, 4,096 checks each.
- [Complete trace parity](parity.json): 2,222 cases in each of four debug/release
  builds, with equal complete output traces.
- [Completion receipt](completion.json): successful timing floor and allocation
  qualification.
- [Reviewed build and source receipt](build-receipt.json): compiler, platform,
  source/header/library/binary hashes and relevant optimization flags, with
  local filesystem paths and raw command output omitted.
- [Executed unit-test summary](unit-tests-summary.json): seven unchanged tests
  in both debug and release; zero failures. This is an extracted component
  execution, not a full application build.
- [Independent audit](independent-audit.json): recomputed every timing and
  allocation summary, verified original source/log hashes and checksums, and
  checked that local unit execution finished before the timing cohort began.
- [Swift download receipt](swift-download-receipt.json) and
  [FFmpeg build receipt](ffmpeg-build-receipt.json): dependency provenance.

## Publication and reproduction scope

The committed observation files contain only numeric measurements and fixed
workload/variant names. Local command logs, absolute filesystem paths, source
snapshot archives and executable binaries are omitted from this public evidence.
The independent audit was performed against the complete original local records.

[The runner](../../run.py) emits full source snapshots, compiler/library/binary
identities, calibration pilots, all observations, traces, and command logs when
rerun. It pins the public baseline and verifies that shared dependencies and
actual demux call sites match the comparison. It retains failed attempts too.
An initial compiler smoke found a Swift 6.3 weak-binding warning in the driver;
that warning was corrected before the sole complete performance cohort.

Normal timed processes did not load the allocation interposer. Only the
separate allocation observations used it. Allocation counters describe
cumulative requested bytes and successful allocation requests, not live or
peak heap/RSS. No timing observation was discarded.

See [the research report](../../../../Documentation/SUBTITLE_ACQUISITION_BORROW_PERFORMANCE.md)
for interpretation, scope, and remaining native macOS integration status.
