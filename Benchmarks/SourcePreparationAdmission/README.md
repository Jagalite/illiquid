# Source preparation admission benchmark

This benchmark investigates the scheduling cost of concurrent background source
preparation. Sidebar directory loading and media-presence scans share
`SourcePreparationExecutor`; interactive source opens use the same physical
worker limit.

The pinned baseline wakes every availability waiter after a physical worker
finishes. Each awakened caller retries admission, and callers that cannot obtain
a slot suspend again with another availability request and deadline timer. A
burst of short directory operations can therefore create repeated scheduling
work while only one new background operation can proceed.

The candidate keeps pending background work in a bounded queue. Physical
completion reserves an available slot for one pending request before dispatching
it. Each request retains one continuation and one deadline across queueing and
execution. The benchmark measures the effect of that change and includes
uncontended controls to expose overhead introduced by the new admission path.

## Reproduce

Run from the repository root with Python 3, Git, and Swift 6.1 or newer. The
component harness uses Foundation and the toolchain's bundled Testing library.
The default baseline commit must be present in the local Git object database:
`a2de305c8dbcaa81aac1477df7c9a0017c14eae3`. A full checkout, or a fetch containing
that commit, is sufficient.

Use a new or empty output directory for each run. On macOS, the runner selects
Swift and the SDK through `xcrun`; `DEVELOPER_DIR` can select the intended Xcode.
`--swift` and `--swiftc`, or the `SWIFT` and `SWIFTC` environment variables, can
select explicit toolchain executables.

```sh
# Contract tests, cancellation stress, and all timing scenarios.
python3 Benchmarks/SourcePreparationAdmission/run.py \
  --mode all --pairs 8 --stress-repetitions 100 \
  --output /tmp/illiquid-source-preparation-all

# Contract tests in debug and release, with no timing measurements.
python3 Benchmarks/SourcePreparationAdmission/run.py \
  --mode test --stress-repetitions 100 \
  --output /tmp/illiquid-source-preparation-tests

# Optimized timing measurements only.
python3 Benchmarks/SourcePreparationAdmission/run.py \
  --mode benchmark --pairs 8 \
  --output /tmp/illiquid-source-preparation-timings

# A focused comparison; --scenario can be repeated.
python3 Benchmarks/SourcePreparationAdmission/run.py \
  --mode benchmark --pairs 8 \
  --scenario background-single --scenario burst-64-directory \
  --output /tmp/illiquid-source-preparation-directory
```

`--mode` defaults to `all`. `--pairs` defaults to 6 and accepts 2–30. Each pair
contains one baseline and one candidate measurement for each selected scenario.
`--stress-repetitions` defaults to 0 and accepts 0–1,000; it applies in `all` and
`test` modes. A repetition launches a fresh test process containing 32
cancellation/handoff races. With 100 repetitions, both implementations and both
build configurations receive 100 processes each: 400 processes and 12,800 race
iterations in a complete successful run, in addition to the ordinary test
suites. A failing command stops the run.

`--baseline REF` selects another baseline explicitly. Keep the recorded baseline
and source hashes with any reported comparison.

## Inputs and build isolation

The runner obtains the complete baseline production file with `git show` and
copies the complete candidate production file from the working tree:

`Sources/IlliquidCore/Utilities/SourcePreparationExecutor.swift`

Each timing executable compiles that file together with `Harness.swift`, using
Swift 6 language mode, `-O`, whole-module optimization, and warnings as errors.
On macOS the build targets macOS 26.0 with the selected SDK. The harness calls
the production `perform` and `performWhenAvailable` APIs.

The correctness stage builds separate minimal Swift packages for the baseline
and candidate. Both receive the same current
`Tests/IlliquidCoreTests/SourcePreparationExecutorTests.swift` and run it in debug
and release. Source files are copied without modifying their implementations.
The runner records hashes of the production files, tests, harness, runner, and
compiled benchmark executables. It also records compiler, platform, baseline
commit, candidate HEAD, working-tree status, and executed commands. It checks
that source inputs have not changed during preparation before starting timings.

## Workloads

Every timing scenario uses capacity 2 and a 12-second request deadline. This is
the default physical concurrency: background work can occupy one slot while an
interactive open can use the other. Three identical warm-up bursts precede the
measured region in each process. A burst completes before the next burst begins.

| Scenario | Requests per burst | Measured bursts | Work inside each request |
| --- | ---: | ---: | --- |
| `interactive-single` | 1 | 2,048 | Uncontended interactive admission and completion |
| `background-single` | 1 | 2,048 | Uncontended background admission and completion |
| `burst-8-empty` | 8 | 256 | No filesystem work |
| `burst-32-empty` | 32 | 64 | No filesystem work |
| `burst-64-empty` | 64 | 32 | No filesystem work |
| `burst-8-100us` | 8 | 64 | Requested 100 μs blocking sleep |
| `burst-32-100us` | 32 | 16 | Requested 100 μs blocking sleep |
| `burst-64-100us` | 64 | 8 | Requested 100 μs blocking sleep |
| `burst-32-1ms` | 32 | 4 | Requested 1 ms blocking sleep |
| `burst-64-1ms` | 64 | 2 | Requested 1 ms blocking sleep |
| `burst-32-directory` | 32 | 16 | Directory enumeration and regular-file checks |
| `burst-64-directory` | 64 | 8 | Directory enumeration and regular-file checks |

The empty scenarios isolate scheduling overhead together with task creation,
cancellation checks, and result collection. The sleeping scenarios provide
controlled blocking work; actual sleep duration depends on host scheduling and
timer resolution.

The directory scenarios use 64 generated local directories containing 16 small
regular files each. Each request enumerates one directory and reads
`isRegularFile` for its entries. The `.mkv` filenames contain small fixture text;
media decoding is not involved. Warm-up makes these warm-cache filesystem
measurements. They do not represent disconnected volumes, network mounts, cold
storage, or complete sidebar refreshes.

For each burst, the harness verifies unique job IDs, the expected completed-job
count, the expected directory-entry count, and drained physical admission. The
runner compares request counts and checksums between paired implementations.

## Interpreting the measurements

Baseline/candidate order alternates AB/BA between pairs. Scenario order also
reverses on alternate pairs to distribute host drift. Each scenario runs in a
separate process for each implementation and pair; process startup and the
three warm-up bursts are excluded from the measured region.

Two metrics are recorded:

- **Wall time:** elapsed monotonic time across the measured bursts, including
  waiting for all their results.
- **Process CPU time:** user plus system CPU time from `getrusage`, summed across
  the process's threads. This includes Swift concurrency, dispatch, admission,
  and the selected work. It is not a single-thread utilization percentage.

`summary.json` reports each implementation's median milliseconds per burst and
the median, minimum, and maximum paired percentage reduction. For each pair the
reduction is `100 × (1 − candidate / baseline)`; a negative value means the
candidate took more time. The median of paired reductions can differ from a
percentage calculated from the two separate medians. The reported range is the
observed pair range, not a confidence interval.

Assess CPU and wall time separately. For blocking work, elapsed time can be
dominated by the requested sleep or filesystem operation while CPU still
reflects scheduler work. Short uncontended controls are sensitive to runtime
and host noise. Inspect all pairs and absolute times before drawing a conclusion;
do not combine differently sized scenarios into an unweighted player-wide
speedup. These component measurements do not establish playback CPU savings,
frame-rate changes, energy savings, or end-to-end input latency.

## Preserved contracts

The shared tests check:

- Background physical concurrency at capacities 1, 2, and 4, and exactly-once
  completion across bursts.
- An interactive slot while background workers and requests are queued; capacity
  1 remains a single shared physical slot.
- The 64-request logical background budget, including active background callers,
  with fail-fast `.busy` results beyond that budget.
- Cancellation and timeout reclaiming logical admission while stalled physical
  work remains counted until it exits.
- Full reuse of the logical budget after cancellation or queued timeouts.
- Queued cancellation and timeout releasing captured work before a blocked
  physical holder exits.
- One deadline covering both queue delay and execution.
- Cancellation racing with physical handoff without duplicate work or leaked
  capacity, followed by successful subsequent admission.

The ordinary suite contains 12 test functions, including parameterized capacity
and captured-lifetime cases. Cancellation stress repeats the handoff test in
fresh processes to exercise more scheduling interleavings.

## Evidence and native qualification

Keep `receipt.json`, `commands.jsonl`, test/stress logs, stress JSON receipts,
`measurements.jsonl`, and `summary.json` together. The raw measurements retain
pair identity and checksums; the summary provides a convenient aggregate.

The `source-preparation-admission.yml` workflow runs the component suite,
100 stress processes per implementation/configuration, and eight timing pairs
on macOS 26 with Xcode 26.6. A separate job builds the application dependency
graph and runs the executor, source-item preparation, media-presence scanner,
and directory-loader tests. Its logs provide integration evidence beyond the
isolated component harness. Workflow artifacts are uploaded even when a job
fails.

This document describes the experiment. Performance conclusions require the
completed run's receipts and measurements.
