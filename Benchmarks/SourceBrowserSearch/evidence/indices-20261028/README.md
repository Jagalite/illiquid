# Matching-index search evidence — October 28, 2026

These records support the
[compact scratch-storage report](../../../../Documentation/SOURCE_BROWSER_SEARCH_SCRATCH_STORAGE.md).

Baseline: `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`.

Measured candidate: `2cd7ea9b7fc80cfcea8d7b7dab5d9d5a26fc5ecd`.

The [Linux job](https://github.com/Jagalite/illiquid/actions/runs/40636607350/job/122644913586)
passed all four baseline/candidate debug/release runs (nine test functions each),
18 timing cases (216 observations), and 18 allocation cases (72 observations).
The macOS job in that run was still queued when this evidence was committed;
this directory makes no native qualification claim.

## Collection and integrity

The workflow prints delimited evidence files to the GitHub job log as well as
uploading its full working evidence directory. The files under `linux/` were
recovered from those exact log blocks after removing only GitHub's per-line
timestamp prefix. No measurements were filtered out. All 17 blocks were
complete and valid JSON/JSONL where applicable.

The [source verification record](linux/source-verification.json) hashes every
recovered file and verifies the candidate Filter, baseline Filter, benchmark
runner, harness, and test runner against the GitHub source bytes. The
[independent audit](linux/audit.json) additionally recomputes every summary
statistic, verifies pairs and output parity, re-fetches source/test files,
and reconstructs portable support declarations and the baseline oracle.

| Record | Meaning |
|---|---|
| `host.txt` | Runner, CPU, OS image, and toolchain information |
| `baseline-*/receipt.json`, `candidate-*/receipt.json` | Exact source/test inputs, compiler, commands, exit status, and reported test count |
| `timing/measurements.jsonl` | All 216 uninstrumented timing observations |
| `allocations/measurements.jsonl` | All 72 separately instrumented observations |
| `summary.json` in each cohort | Medians, ranges, every paired reduction, and favorable-pair counts |
| `environment.json` | Baseline and checkout SHA, source hashes, affinity, and compiler |
| `*-build.json` | Executable, compiled source, oracle, manifest, and harness hashes |
| `completion.json` | Completed case/observation counts |

Full command/build logs, calibration files, staged sources, and runner snapshots
are also in the workflow artifact, subject to its 14-day retention. This commit
retains the raw measured observations and provenance listed above; it does not
claim to archive the full artifact ZIP or all compiler logs. Exact source is
recoverable from the measured Git commit.

These measurements concern constructed component workloads. Requested allocation
bytes are cumulative allocator traffic, not live heap, peak memory, RSS, or
macOS player footprint. The timing cohort was not allocation-instrumented.
