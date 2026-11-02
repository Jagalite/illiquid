# Read-ahead wakeup results

## Finding and tradeoff

The optimization eliminates advancing-position broadcasts when a read-ahead
reader cannot proceed. Fresh Linux measurements show **zero broadcasts and
zero wait returns during the measured EOF and far-future update intervals**,
compared with 119–479 broadcasts and 59–239 wait returns in the baseline.
Process CPU in the EOF/future traces falls by 46.0–53.6% in these isolated two-second
traces. The candidate uses less CPU in all 36 EOF/future paired comparisons.

This is a successful bounded reduction in needless notifications, not a general
player speedup. The active-reader control retains every admission but has
**3.3–3.5% higher CPU medians at 60/120 Hz** (0.306–0.546 ms extra CPU per
two-second trace). Its 30 Hz median is 1.0% lower. The historical Mac run also
has higher active/no-reader control medians. These adverse controls are retained
as a tradeoff for review; the data do not establish lower CPU for ordinary
continuously active playback.

Current macOS component and full app integration checks remain pending at the
time of this report. Follow the PR checks for their current status. Historical
native component qualification is supporting evidence, not a current-head app
integration result.

## Source provenance

- Baseline: current main at
  [`ea2ff568`](https://github.com/Jagalite/illiquid/commit/ea2ff568237e2667f7b1aeee67b11a44ebe95b72).
- Fresh measured candidate:
  [`ecb431b6`](https://github.com/Jagalite/illiquid/commit/ecb431b6b10993fac46de59a9a4e505bbdb65355).
- Reused unmerged experiment:
  [`2bea445f`](https://github.com/Jagalite/illiquid/commit/2bea445f23e65f238ca46539fa2b63169f1ffebb).
- The old frozen gate baseline and current main are byte-identical (Git blob
  `10374be342abef4546031d6edd988566b31a62b0`). The port preserves the candidate
  gate, regression tests, driver, and counting wrapper from the old experiment.
  Both cohorts' manifests retain their source hashes.
- The fresh runner pins the current-main baseline, uses warnings as errors,
  requires complete 15-test receipts, and accepts Swift Testing's old summary
  format and Swift 6.4's added suite count.
- Subsequent publication changes add documentation/evidence and remove the
  research-branch-only CI trigger. Production, test, driver, wrapper, and runner
  hashes remain those of the measured candidate.

## Fresh Linux result

[Successful Linux job](https://github.com/Jagalite/illiquid/actions/runs/40639644825/job/122654539045)
on Ubuntu 24.04, x86_64, Swift 6.4. All measurements below use the same
`-O -whole-module-optimization -swift-version 6 -warnings-as-errors` flags.
Each normal trace is paced for approximately two seconds.

Broadcasts and wait returns are from the separate instrumented build. CPU is
the median of six fresh-process pairs from the **uninstrumented** Foundation
build. Negative CPU change means less CPU; positive means more CPU. Pairs
alternate AB/BA and reverse scenario order. No samples are discarded and no
controller overhead is subtracted.

| Synthetic cadence | Case | Broadcasts, baseline → candidate | Wait returns, baseline → candidate | Process CPU ms, baseline → candidate | CPU change |
|---|---|---:|---:|---:|---:|
| 30 Hz | EOF | 119 → 0 | 59 → 0 | 3.618 → 1.777 | -50.9% |
| 30 Hz | Far-future timestamp | 119 → 0 | 59 → 0 | 3.353 → 1.810 | -46.0% |
| 30 Hz | Active admissions | 119 → 60 | 60 → 60 | 4.725 → 4.677 | -1.0% |
| 30 Hz | No reader | 60 → 0 | 0 → 0 | 1.856 → 1.903 | +2.5% |
| 60 Hz | EOF | 239 → 0 | 119 → 0 | 6.726 → 3.322 | -50.6% |
| 60 Hz | Far-future timestamp | 239 → 0 | 119 → 0 | 6.574 → 3.244 | -50.7% |
| 60 Hz | Active admissions | 239 → 120 | 120 → 120 | 8.719 → 9.025 | +3.5% |
| 60 Hz | No reader | 120 → 0 | 0 → 0 | 3.562 → 3.138 | -11.9% |
| 120 Hz | EOF | 479 → 0 | 239 → 0 | 12.379 → 6.223 | -49.7% |
| 120 Hz | Far-future timestamp | 479 → 0 | 239 → 0 | 13.086 → 6.072 | -53.6% |
| 120 Hz | Active admissions | 479 → 240 | 240 → 240 | 16.315 → 16.860 | +3.3% |
| 120 Hz | No reader | 240 → 0 | 0 → 0 | 6.541 → 6.596 | +0.8% |

The primary evidence is the notification reduction. CPU includes both the
reader and controller/pacing thread. Elapsed wall time is intentionally about
two seconds and is not a throughput improvement. A last signaled reader can
still be runnable when counters are captured; these are measured interval
deltas, not guaranteed notification delivery totals.

All six EOF pairs and all six future-timestamp pairs at each cadence favor the
candidate. Active-admission CPU favors the candidate in 3/6 pairs at 30 Hz,
2/6 at 60 Hz, and 1/6 at 120 Hz. Ranges and every paired result are retained in
the raw summaries and measurements.

The four-reader EOF case is an instrumented adversarial control, not a model
of normal player concurrency. Baseline broadcast counts are 44,517 at 30 Hz,
22,739 at 60 Hz, and 11,724 at 120 Hz; candidate counts are zero. The control uses
24 updates, so its elapsed window differs by cadence. No CPU claim is made
from that instrumented case.

## Correctness and evidence audit

The same 15 production regression tests pass against baseline and candidate
in both debug and release: four configurations, 60 test executions. They cover
exact and rounded admission boundaries, overflow/infinite timestamps, EOF,
monotonic progress, mixed readers, consecutive updates, seek invalidation,
same-generation reset, close, diagnostic observers, and reset/update races.

Each cadence also runs 81 synchronized semantic checks per variant. Diagnostic
observers and mixed readers are verified to be inside actual condition waits.
Baseline/candidate semantic receipts agree. Every active trace admits all of
its timestamps; no EOF/future reader completes during progress; close rejects
and releases all remaining waiters.

The retained evidence audit verifies:

- All emitted files against the SHA-256 hashes recorded by CI.
- The measured commit, production source hashes, clean checkout, input count,
  and pacing interval for every cohort.
- 58 raw rows per cadence: 10 counting rows and 48 uninstrumented timing rows.
  Across three cadences, all 174 rows are retained.
- Six complete baseline/candidate pairs per normal scenario, their alternating
  order, matching receipts, and required zero-broadcast cases.

See [the machine-readable audit](evidence/linux-current-20261028/audit.json),
[test completions](evidence/linux-current-20261028/120hz/tests.json), and the
[120 Hz](evidence/linux-current-20261028/120hz/),
[60 Hz](evidence/linux-current-20261028/60hz/), and
[30 Hz](evidence/linux-current-20261028/30hz/) raw cohorts.

The first current-branch run,
[`40639369632`](https://github.com/Jagalite/illiquid/actions/runs/40639369632),
passed all 15 baseline debug tests but the runner rejected Swift 6.4's
`in 1 suite` completion wording. No benchmark ran. Its
[separate receipt](evidence/linux-parser-attempt/) is preserved and excluded
from all performance summaries. The corrected parser still requires the exact
nonempty test count and a passing completion.

## Historical macOS support

[Native run from 2026-10-21](https://github.com/Jagalite/illiquid/actions/runs/39666970810/job/119454464025)
used macOS 26.6.2, an Apple M1 virtual machine, and Apple Swift 6.3.3. Its
baseline, candidate, test, driver, and counting-wrapper hashes match this
study's corresponding files. All four 15-test configurations passed. The
downloaded artifact's ZIP SHA-256 was verified against the original job log.

This cohort is historical and is not pooled with Linux or presented as a
fresh run of current main. It used the original runner without warnings as
errors. The following medians are from six pairs of the 120 Hz trace.

| Case | Broadcasts, baseline → candidate | Process CPU ms, baseline → candidate | CPU change |
|---|---:|---:|---:|
| EOF | 356 → 0 | 4.340 → 2.406 | -44.6% |
| Far-future timestamp | 360 → 0 | 4.641 → 2.393 | -48.4% |
| Active admissions | 479 → 240 | 6.873 → 7.639 | +11.1% |
| No reader | 240 → 0 | 2.346 → 2.685 | +14.5% |

The active control is 0.766 ms higher and the no-reader control 0.339 ms higher
per approximately two-second trace. Those results are retained without claiming
that scheduler noise proves the increases harmless. They reinforce the need to
scope this change to unnecessary notification avoidance.

The [historical evidence directory](evidence/historical-macos-20261021/)
contains the unmodified artifact files plus a provenance record linking the
original run, commit, artifact ID, and ZIP hash.

## Why the change is safe to evaluate

A reader advertises its blocked timestamp under the existing condition lock.
An update broadcasts only when the current lookahead sum can satisfy the
earliest advertised timestamp. Before broadcasting, it clears that cached
threshold. All signaled readers are already runnable; each either observes the
latest state and completes or re-advertises its threshold before sleeping.
Reset and close still broadcast unconditionally. Diagnostic observers still
receive a broadcast when a reader first registers.

EOF readers advertise no timestamp. Registration occurs once per wait call,
so a reader returning to its condition wait does not itself repeatedly notify
other blocked readers. The original `timestamp > position + lookahead`
predicate and its floating-point arithmetic are unchanged.

## Application limits

Only the subtitle gate receives playback-position updates. The audio and
demux EOF gates share the implementation but do not receive these periodic
updates. In [MediaSession](../../Sources/IlliquidNativePlayback/Media/MediaSession.swift),
the subtitle worker applies read-ahead gating before filtering the selected
stream, so ordinary multiplexed input can still require active admission even
when captions are sparse.

The traces use synthetic observation pacing, not measured player update
frequency. Position advances by 1/120 second per update at every cadence; the
lower-rate cohorts vary pacing without changing admission arithmetic. There is
no measurement of whole-player CPU, battery, frame rate, visible subtitle
latency, live playback, or physical-device power. Fresh native app integration
is the remaining validation gap.

Reproduction commands and build details are in [README.md](README.md).
