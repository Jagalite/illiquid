# Batch-open selection: performance evidence

## Result and qualification

The portable component experiment passed and reduced ordinary middle, last
and missing-current selection times by 61.6–67.3% in this Linux run. The
production change removes the second playlist identity scan in
`PlaybackController.applyOpenPlan`; it adds no cache or new public API.

- Baseline: [`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`](https://github.com/Jagalite/illiquid/commit/ea2ff568237e2667f7b1aeee67b11a44ebe95b72).
- Measured candidate: [`c7300e8d3b4376e3f6cbe04cf5acaac52a7ec0d8`](https://github.com/Jagalite/illiquid/commit/c7300e8d3b4376e3f6cbe04cf5acaac52a7ec0d8).
- [Portable run 40637752504](https://github.com/Jagalite/illiquid/actions/runs/40637752504),
  [job 122648536124](https://github.com/Jagalite/illiquid/actions/runs/40637752504/job/122648536124):
  **passed**, completed October 28, 2026 at 05:25 UTC.
- Swift 6.4.1, x86_64 Linux, Ubuntu 24.04 hosted runner.
- Four component builds (baseline/candidate × debug/release), each with
  **2,102 independent expected outcomes**, passed with checksum **31,498**.
- All **320 timed samples** and **135 calibration samples** are retained.
  An independent audit recomputed summaries, matched both output fields and
  checksums for each pair, and checked balanced AB/BA ordering.

The [macOS run 40636133102](https://github.com/Jagalite/illiquid/actions/runs/40636133102)
was still **queued** when this evidence was recorded. Neither its native
component timings nor full-application/controller tests are claimed as
completed. The draft PR remains pending that native qualification.

## Complete timing results

Each row uses eight baseline/candidate pairs in fresh processes. The table
shows the median time per call for each variant. Speedup is the median of
the eight paired ratios; its range is the observed pair range, not a
confidence interval. Fixture preparation is outside timing.

| Items | Case | Baseline ms/call | Candidate ms/call | Time reduction | Paired speedup median (range) |
| ---: | --- | ---: | ---: | ---: | --- |
| 0 | empty | 0.000002843 | 0.000002632 | 7.4% | 1.09× (1.04–1.15×) |
| 1 | first | 0.004156 | 0.004131 | 0.6% | 1.01× (0.99–1.04×) |
| 1 | miss | 0.003887 | 0.003900 | -0.3% | 1.00× (0.95–1.01×) |
| 1 | nil-current | 0.000002785 | 0.000002558 | 8.1% | 1.07× (0.94–1.20×) |
| 1 | invalid-current | 0.002074 | 0.002095 | -1.0% | 0.99× (0.96–1.01×) |
| 32 | first | 0.008289 | 0.008253 | 0.4% | 1.00× (0.98–1.02×) |
| 32 | middle | 0.108568 | 0.041719 | 61.6% | 2.62× (2.53–2.68×) |
| 32 | last | 0.202491 | 0.073855 | 63.5% | 2.74× (2.66–2.79×) |
| 32 | miss | 0.190971 | 0.071378 | 62.6% | 2.68× (2.64–2.77×) |
| 1,000 | first | 0.008296 | 0.008372 | -0.9% | 0.99× (0.98–1.01×) |
| 1,000 | middle | 3.2169 | 1.0854 | 66.3% | 2.94× (2.87–3.07×) |
| 1,000 | last | 6.4434 | 2.1840 | 66.1% | 2.96× (2.86–3.01×) |
| 1,000 | miss | 5.9731 | 2.0677 | 65.4% | 2.88× (2.79–2.91×) |
| 10,000 | first | 0.008268 | 0.008393 | -1.5% | 1.00× (0.96–1.12×) |
| 10,000 | last | 63.2304 | 20.6951 | 67.3% | 3.02× (2.77–3.11×) |
| 10,000 | miss | 61.7762 | 21.0559 | 65.9% | 2.92× (2.64–3.32×) |
| 1,000 | unicode-alias | 5.3145 | 1.7481 | 67.1% | 3.01× (2.91–3.08×) |
| 1,000 | invalid-current | 2.0800 | 0.002178 | 99.9% | 958.77× (945.09–1001.25×) |
| 1,000 | all-invalid | 0.026526 | 0.014119 | 46.8% | 1.87× (1.85–1.93×) |
| 1,000 | nil-current | 0.000002737 | 0.000002502 | 8.6% | 1.11× (1.02–1.44×) |

The main large-playlist result is the 10,000-item last-match case:
**63.23 → 20.70 ms**, a **67.3% reduction** in this computation. The
1,000-item last-match case is **6.44 → 2.18 ms**, a **66.1% reduction**.

First-match and singleton identity controls are approximately unchanged.
The largest median slowdown among these controls is **1.5%** in the
10,000-item first-match case (**8.268 → 8.393 microseconds**); its paired
speedup range crosses 1. Do not interpret nanosecond-scale empty or
nil-target controls as meaningful user-visible gains.

The unsupported-current case is retained for completeness. Its very large
ratio comes from avoiding a full scan after the target identity has already
been rejected; it is an edge case, not a representative normal playback
speedup.

## Why the behavior is preserved

The existing selection helper returns the first matching identity before
considering its fallback. A single comparison of the selected item can
therefore distinguish a preserved current file from a fallback. That
comparison is still required for singletons, since their selection helper
returns index 0 without doing an identity comparison.

Both variants require valid normalized identities; invalid URLs do not
match each other. Nil-current and empty-list behavior is unchanged. The
separate `reopensStoppedSelection` condition still creates a fresh session
for an explicit replacement open after Stop.

The added controller regressions cover replace and append modes with a
matching singleton, middle item and final item; ownership of subsequent
position observations; and replacement with a missing current identity
without committing the new playlist before the load succeeds. Those native
controller tests are part of the queued macOS job, not the portable result.

## Method and limits

See [the benchmark method and reproduction command](../../../Benchmarks/BatchOpenSelection/README.md)
and [runner](../../../Benchmarks/BatchOpenSelection/run.py).

The runner extracts the exact selection-plus-preservation block from both
complete controller snapshots. All four helper files must be byte-identical
to the baseline. It compiles the component separately from the measurement
driver, without cross-module optimization, and consumes both the selected
index and preservation flag in a checked checksum.

The extracted block and core helpers are compiled together inside
`BatchOpenComponent`; the actual app imports `IlliquidCore` across a module
boundary. These are **Linux component measurements**. They do not establish
native macOS timing, full-controller latency, first-frame latency, decoding
throughput, live UI responsiveness, or playback frame rate. No live UI
qualification was performed.

## Retained records

- [manifest.json](linux/manifest.json): exact commits, compiler, platform,
  source and binary SHA-256 values, extraction boundaries, compiler flags.
- [summary.json](linux/summary.json): all four verification receipts and all
  twenty timing summaries.
- [measurements.jsonl](linux/measurements.jsonl): all 320 raw timed samples.
- [calibration.jsonl](linux/calibration.jsonl): all 135 calibration samples.
- [audit.json](linux/audit.json): independent summary, witness and ordering
  checks.

These files were recovered from the workflow's structured job-log records.
The workflow also uploads full source snapshots, commands and build logs as
a GitHub artifact with a 14-day retention period. The committed records
above preserve the numerical evidence after that artifact expires.
