# Source preparation admission research

## Outcome

The bounded handoff candidate reduced CPU cost in every contended native macOS
comparison. For 32/64 warm directory reads, the median paired reductions were
**43.5%/57.7% in process CPU** and **22.9%/32.6% in elapsed time**. Both metrics
improved in all eight pairs for each directory workload. These component results
support proposing the optimization; they do not measure whole-player speed.

The [native qualification run](https://github.com/Jagalite/illiquid/actions/runs/39669100025)
passed the same contract suite for the baseline and candidate in debug and
release, 12,800 additional cancellation/handoff iterations, and 21 app integration
tests. The measured candidate is
[`4a08e50d1bf62553a4066756632bf7a51b49bbbf`](https://github.com/Jagalite/illiquid/commit/4a08e50d1bf62553a4066756632bf7a51b49bbbf);
subsequent research documentation does not change its code, tests, or harness.
The [evidence index](PerformanceEvidence/SourcePreparationAdmission/README.md)
contains durable copies of the raw data and validation receipts.

## Scope and hypothesis

This research targets scheduling overhead in `SourcePreparationExecutor`, used
by background directory expansion, recursive media discovery, and media-presence
scans. Interactive file opens share its bounded physical worker pool.

The baseline is commit
[`a2de305c8dbcaa81aac1477df7c9a0017c14eae3`](https://github.com/Jagalite/illiquid/commit/a2de305c8dbcaa81aac1477df7c9a0017c14eae3).
Its `performWhenAvailable` retries admission after receiving an availability
notification. Physical completion wakes **every** availability waiter even when
only one background slot can be used. Losing callers allocate another request,
continuation, UUID, and deadline timer before waiting again. With many short
operations, this can make scheduling cost much larger than the filesystem work.

The production callers are `SourceDirectoryLoader` and
`SourceRecursiveMediaLoader` in
[`SourcesSidebar.swift`](../Sources/IlliquidApp/UI/SourcesSidebar.swift), plus
[`SourceMediaPresenceScanner`](../Sources/IlliquidApp/UI/SourceMediaPresenceScanner.swift).
The default executor has two physical slots, reserves one for interactive work,
admits at most 64 logical background calls, and applies a 12-second deadline.

## Change

The candidate keeps one request and one absolute deadline per logical call.
Background work that cannot start immediately enters a bounded FIFO queue.
When physical work exits, the executor reserves an available slot for at most
one pending background request and dispatches it outside the scheduler lock.
It no longer broadcasts availability or repeatedly constructs losing admission
attempts.

Admission uses the existing request object's identity instead of generating a
UUID for each background call. Pending or dispatched work keeps that request
alive, and the one successful completion retires its identity synchronously
before resuming the caller. This avoids identifier generation without allowing
a later allocation to be removed by an old completion.

Cancellation and timeout remove queued work and release its captures outside the
scheduler lock. They release the logical background budget promptly, but an OS
operation that has already started keeps its physical slot until it returns.
Interactive admission remains fail-fast. At capacity one, interactive and
background work still share the single physical slot.

Two handoff details matter for correctness. The deadline timer is armed before
queued work becomes visible to a completing worker. The worker also checks the
absolute deadline before entering the filesystem closure, because timer delivery
can lag. Completion callbacks acquire the executor lock only after releasing
the request lock.

The array queue is bounded by 64 logical calls. Removing its first element or a
canceled entry can still shift a bounded number of references; this change does
not claim that every queue operation has constant cost. It removes repeated
task wakeups and request/timer construction from contended admission.

## Experiment

The harness compiles each **complete, unmodified production executor file**
with the same benchmark source. It uses Swift 6 language mode, `-O`,
whole-module optimization, and warnings as errors. No alternate scheduler is
substituted for either implementation.

The workload covers uncontended interactive and background calls, bursts of
8/32/64 empty operations, bursts with requested 100-microsecond or one-millisecond
blocking work, and warm directory enumeration with regular-file metadata checks.
The directory fixture has 64 directories with 16 regular files each. Capacity
and timeout remain at their production defaults.

Each process warms the runtime and filesystem with three unmeasured bursts.
Baseline/candidate order alternates AB/BA between pairs; scenario order reverses
on alternate pairs. Every burst verifies unique results, completed-job counts,
directory-entry counts, and drained physical admission. Paired executions must
have matching behavioral receipts.

Wall time measures elapsed burst completion. CPU time is process user plus
system CPU summed across threads. Reported percentages are the median of the
paired reductions, `100 * (1 - candidate / baseline)`, and can differ from a
ratio of the two separately reported medians. Pair ranges describe observed
variation, not confidence intervals.

See the [benchmark README](../Benchmarks/SourcePreparationAdmission/README.md)
for all scenario sizes, flags, and reproduction commands.

## Results

### Primary native macOS comparison

The October 21, 2026 run used a GitHub `macos-26` runner reporting Apple M1
(Virtual), three logical CPUs, macOS 26.6.2, Xcode 26.6, and Apple Swift 6.3.3.
Eight balanced pairs across 12 scenarios produced 192 measurements. Both variants
used the same compiler and flags; the receipt records their exact source and
binary hashes.

All 80 contended CPU pairs improved. Across contended scenarios, median paired
CPU reductions ranged from 42.8% to 77.7%. The table includes the uncontended
controls and every timing workload. CPU times are milliseconds per entire burst.

| Workload | Baseline CPU ms | Candidate CPU ms | Median paired CPU reduction | Median paired wall reduction |
| --- | ---: | ---: | ---: | ---: |
| Interactive single | 0.121 | 0.110 | 4.4% | 9.9% |
| Background single | 0.158 | 0.150 | 4.5% | 7.3% |
| 8 empty jobs | 0.998 | 0.506 | 47.8% | 41.9% |
| 32 empty jobs | 4.932 | 1.439 | 64.6% | 61.0% |
| 64 empty jobs | 9.362 | 2.886 | 69.3% | 65.0% |
| 8 jobs, 100 μs work | 3.528 | 1.881 | 42.8% | 6.5% |
| 32 jobs, 100 μs work | 20.508 | 6.612 | 66.8% | 16.3% |
| 64 jobs, 100 μs work | 66.355 | 16.231 | 77.7% | 17.7% |
| 32 jobs, 1 ms work | 32.185 | 10.536 | 65.8% | 0.4% |
| 64 jobs, 1 ms work | 83.153 | 22.700 | 71.8% | 2.4% |
| 32 warm directory reads | 27.561 | 16.348 | 43.5% | 22.9% |
| 64 warm directory reads | 78.754 | 32.470 | 57.7% | 32.6% |

The two CPU columns are separately computed medians; the percentage columns
summarize paired reductions. Positive reductions mean lower candidate cost.
For directory work, the observed paired CPU ranges were 33.9–57.7% (32 reads)
and 43.9–69.5% (64 reads); wall reductions ranged from 7.4–41.6% and 5.1–71.6%.

The single-call controls are noisy. Their CPU ranges include regressions:
-17.1% to 30.0% for interactive and -12.5% to 12.5% for background calls.
Small positive median reductions do not establish equivalence or an uncontended
speedup. The primary claim is the repeatable reduction in contended CPU work.

Sleep-heavy elapsed time is also unstable. In the 1 ms scenarios, median paired
wall reductions were only 0.4%/2.4%; the 64-job pair range was -84.2% to 20.7%.
Its separately computed median wall time increased from 484.3 ms to 569.0 ms,
despite the small positive median paired percentage. The requested sleeps are
not precise durations on this virtualized runner. These measurements support
lower scheduler CPU, but not a consistent latency gain for blocking operations.

Raw measurements, exact ranges, test logs, and compiler/environment receipts:
[native evidence](PerformanceEvidence/SourcePreparationAdmission/native/).

### Supporting Linux comparison

The final source was compared in six pairs on the shared Linux host, outside
the mismatched PID namespace. All 60 contended CPU comparisons improved. These
results support the mechanism; native macOS measurements are the primary result.

| Workload | Median paired CPU reduction | Observed CPU range | Median paired wall reduction |
| --- | ---: | ---: | ---: |
| Interactive single | -2.2% | -45.6% to 7.9% | -4.9% |
| Background single | 13.8% | -11.6% to 25.7% | 6.5% |
| 8 empty jobs | 43.4% | 32.4% to 54.2% | 50.9% |
| 32 empty jobs | 62.7% | 48.4% to 70.2% | 50.1% |
| 64 empty jobs | 74.1% | 49.8% to 78.7% | 51.7% |
| 8 jobs, 100 μs work | 56.8% | 44.3% to 63.3% | 28.7% |
| 32 jobs, 100 μs work | 79.5% | 64.9% to 80.8% | 39.7% |
| 64 jobs, 100 μs work | 82.7% | 78.1% to 88.5% | 42.8% |
| 32 jobs, 1 ms work | 77.7% | 69.8% to 80.7% | 24.8% |
| 64 jobs, 1 ms work | 82.2% | 75.7% to 89.0% | 18.5% |
| 32 warm directory reads | 22.0% | 18.6% to 40.0% | 17.0% |
| 64 warm directory reads | 41.5% | 21.7% to 50.6% | 26.2% |

Positive reductions mean lower candidate cost; negative values mean higher cost.
The interactive control was sensitive to run order and host conditions, so its
near-zero median does not prove equivalence. The background control improved
in five of six CPU pairs. Directory CPU improved in every pair, while directory
wall time worsened in one pair per size. These data do not establish a uniform
directory-loading latency improvement.

The first queued candidate generated a UUID for every background call. A later
refinement reused the request identity. The final measurements above use the
refined source; earlier candidate and preliminary sandbox measurements are not
mixed into these summaries. Separate runs do not isolate the causal effect of
identifier generation from changing host conditions.

Raw measurements and receipts: [Linux evidence](PerformanceEvidence/SourcePreparationAdmission/linux/).

## Validation

Both implementations receive the same current contract tests in separate minimal
Swift packages, in debug and release. The suite covers:

- Physical background limits at capacities 1, 2, and 4, and exactly-once work.
- The 64-call logical background budget and full reuse after cancellation or
  queued timeout.
- Interactive capacity while background work is blocked and queued.
- Prompt logical retirement while physical OS work remains counted.
- Release of canceled or expired queued captures before a blocked holder exits.
- One deadline covering queue delay and execution.
- Cancellation racing with physical handoff, followed by successful reuse.

The native workflow additionally builds the app dependency graph and runs
`SourcePreparationExecutorTests`, `SourceItemPreparationTests`,
`SourceMediaPresenceScannerTests`, and the directory-loader regression test.

The completed native run passed all four component suite executions: 12 test
functions for each implementation in each build configuration. Parameterized
capacity and captured-lifetime cases are included. Each of those four combinations
also passed 100 fresh stress processes containing 32 cancellation/handoff races:
400 processes, 12,800 iterations total, 6,400 per implementation. The application
dependency graph built successfully, and its selected integration run passed
21 tests across four suites. This is a targeted integration run, not the entire
repository test suite.

The final candidate also passed both component configurations and 1,920 additional
handoff iterations on Linux outside the mismatched namespace. Its local contract
receipt is separate from the final six-pair timing receipt, which was produced
in benchmark-only mode. Native qualification is the primary correctness gate.

## Linux diagnostic exclusion

Preliminary execution inside the local process sandbox produced intermittent
SIGILL failures in **both** the unchanged baseline and the candidate, including
a standalone benchmark without cancellation. These preliminary timings are
excluded.

A symbolized stack and a temporary diagnostic preload traced the fault to
Linux libdispatch's worker-pool monitor. The process saw PID 62 while
`/proc/self` resolved to host PID 74815. Libdispatch attempted to open
`/proc/63/stat` for a namespace worker ID, received `ENOENT`, and executed its
registered-worker-missing trap. The
[Swift 6.3.2 libdispatch source](https://github.com/swiftlang/swift-corelibs-libdispatch/blob/swift-6.3.2-RELEASE/src/event/workqueue.c)
contains that exact failure path.

Qualification was rerun outside the mismatched namespace, without the diagnostic
preload or runtime changes. A separate receipt verifies matching process and
procfs IDs in that environment. Production code and behavioral tests were not
weakened to avoid the fault.

## Limits

These are component measurements of admission plus the stated work. They do not
measure whole-player CPU, rendering, playback smoothness, energy, or end-to-end
sidebar latency. Warm local directory fixtures do not model cold storage,
network mounts, disconnected volumes, or metadata-heavy media libraries.
Blocking sleeps are controlled stand-ins whose actual duration depends on the
host scheduler.

The contract tests establish that stalled physical work continues to consume
capacity after logical cancellation. This optimization cannot interrupt a
filesystem call that the OS does not return.
