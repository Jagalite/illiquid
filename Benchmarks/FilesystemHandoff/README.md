# Bounded filesystem callback handoff

## Finding and change

The sidebar already bounds events waiting for its debounce timer, but the
production monitor previously created a separate main-actor task for every
worker callback. Each task captured the entire callback array. If the main actor
was busy, those arrays accumulated before reaching the sidebar's bounded buffer.

This change gives each watcher generation a lock-protected
`SourceFilesystemEventMailbox`. Callbacks append to the existing
`SourceFilesystemEventBuffer`, and only the transition from no pending delivery
to pending delivery schedules a task. That task captures the mailbox instead of
the callback array.

Up to 4,096 events remain ordered and unchanged. Overflow or an explicit native
loss marker collapses pending detail to the existing `eventsDropped` marker,
whose planner meaning is a rescan of every current watched root. This is the
same recovery policy already used by the sidebar. The budget is an internal
event-count limit, not a byte bound or a platform-derived optimum.

Draining the buffer and relinquishing the pending-delivery flag happen under
one lock. A callback racing the drain either joins that delivery or schedules
the next one. No lock is held while calling the main-actor handler. Stop and
deinitialization clear the mailbox immediately; restart creates a distinct
mailbox, while the existing generation checks reject stale callbacks and tasks.

## Reproduction

From a macOS checkout containing baseline commit
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`:

~~~sh
bash Scripts/test-filesystem-handoff.sh --configuration debug --jobs 2 -Xswiftc -warnings-as-errors
bash Scripts/test-filesystem-handoff.sh --configuration release --jobs 2 -Xswiftc -warnings-as-errors
python3 Benchmarks/FilesystemHandoff/run.py --pairs 6 --output /tmp/filesystem-handoff
~~~

The output directory must not already exist. Follow the root `AGENTS.md` build
coordination policy: submit compilation through Kyoto when it is available.
The dedicated workflow explicitly explains the unavailable queue on hosted
runners and compiles isolated components serially.

The focused test package includes the **complete, unmodified production monitor**
and its actual policy, mailbox, and lifecycle-instrumentation dependencies.
It runs new mailbox concurrency and monitor handoff tests alongside the existing
lifecycle, native FSEvents, volume, buffer, event-loss, root-routing, and planner
tests. It does not build the unrelated native media graph.

## Experiment

Both variants compile their complete production `SourceFilesystemMonitor.swift`.
The baseline comes from the pinned Git commit; the candidate comes from the
checkout. The other existing production dependencies are also copied in full,
and the candidate includes its mailbox. No substitute monitor, event policy,
AppKit, Foundation, or task scheduler is used.

A fake stream is injected through the monitor's existing worker factory. Startup
reconciliation is delivered before the measurement. The main actor then remains
synchronously occupied while the worker emits fresh callback batches. Input
batches leave scope before the held-memory sample, so the primary measurement
covers ownership retained by pending deliveries, not a benchmark-owned input
array. The driver subsequently lets delivery finish and checks the actual
downstream buffer and invalidation plan.

The experiment uses fresh processes and six pairs per workload, balanced between
baseline/candidate and candidate/baseline order. Controls contain one event,
32 one-event callbacks, and exactly 4,096 events. Stress cases cover 4,097 events,
100,000 events in 128- and 16-event batches, and one oversized 100,000-event
callback. These are synthetic backlogs, not measured user activity rates.

The primary metric is signed live allocator growth from a warmed pre-burst sample
to the sample while the main actor is still occupied:
`malloc_zone_statistics(NULL).size_in_use` across all malloc zones. It is
**not RSS, physical footprint, or peak process memory**. The mailbox's fixed
startup allocation is already present in the pre-burst sample and is excluded
from this growth metric; small-burst deltas are not the complete per-monitor
footprint. Allocator/runtime caches may contribute to the delta. After-delivery and after-stop readings retain the
same downstream buffer in both variants and therefore need not return to the
pre-burst value.

All detailed planner verification and JSON serialization occur after memory
sampling. Ordinary controls validate full events, flags, order, and planner
parity. Both variants' downstream buffers must produce the same all-root recovery
plan after overflow. Measured handler counts describe this stalled-actor
experiment; they are not a general scheduling-latency measurement.

The runner retains source and binary hashes, compiler/host metadata, commands,
copied production source, all raw observations, paired differences and ranges.
The workflow also preserves debug/release test logs. Compact machine-readable
evidence is printed in CI logs as well as uploaded as an artifact.

## macOS validation results

**Validated:** [push run 40772562248](https://github.com/Jagalite/illiquid/actions/runs/40772562248), [job 123113329840](https://github.com/Jagalite/illiquid/actions/runs/40772562248/job/123113329840), and [raw workflow artifact](https://github.com/Jagalite/illiquid/actions/runs/40772562248/artifacts/12869996606). **Exact candidate tested:** `ea2a78ebd5fdfff09f251dc2e4a61e2209246c0e`; **frozen baseline:** `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`. The evidence-only follow-up commit does not change tested implementation or harness code. The [durable parsed receipts](evidence/macos/run-40772562248/) include all 84 observations, paired differences, summary/ranges, source and executable hashes, environment, verification, test logs and command outcomes.

On GitHub-hosted `macos-26` ARM64 (macOS 26.6.2, Xcode 26.6, Apple Swift 6.3.3; macOS 26.5 SDK), **debug and release each passed 80 tests in 11 suites** using Swift 6 and warnings as errors. The isolated full production-monitor tests include real FSEvents delivery, mailbox races/concurrent producers, stop/restart/deinit, overflow and planner behavior. The benchmark compiled baseline and candidate production sources with the same hashed `Driver.swift`; hashes of staged production code matched their pinned Git revisions, and the runner/driver/heap/test script SHA-256 matched the candidate revision. All 84 fresh-process observations (six balanced pairs × seven workloads) verified, including original event path/flag/order and planner semantics within capacity, all-root recovery on overflow, and **identical downstream semantics across both variants** for each workload.

**Held allocator growth in MiB** (signed `malloc_zone_statistics(NULL).size_in_use` after warmed startup, measured before the stalled main actor resumes). Each value is **median (minimum to maximum)** over six runs per variant or six paired baseline-minus-candidate differences:

| Workload | Baseline growth MiB | Candidate growth MiB | Paired savings MiB | Handler deliveries, baseline → candidate |
| --- | ---: | ---: | ---: | ---: |
| `single` (1, batches of 1) | 0.002 (0.002 to 0.006) | 0.002 (0.002 to 0.006) | 0.000 (-0.004 to 0.004) | 1 → 1 |
| `small-32` (32, batches of 1) | 0.053 (0.049 to 0.053) | 0.008 (0.008 to 0.012) | 0.043 (0.041 to 0.045) | 32 → 1 |
| `boundary-4096` (4,096, batches of 128) | 0.904 (0.793 to 0.975) | 0.876 (0.832 to 0.956) | 0.028 (-0.083 to 0.130) | 32 → 1 |
| `overflow-4097` (4,097, batches of 128) | 0.884 (0.861 to 0.910) | 0.001 (-0.043 to 0.005) | 0.905 (0.860 to 0.905) | 33 → 1 |
| `storm-100k` (100,000, batches of 128) | 22.122 (22.085 to 22.152) | 0.036 (-0.064 to 0.064) | 22.094 (22.041 to 22.149) | 782 → 1 |
| `storm-100k-small-batches` (100,000, batches of 16) | 29.785 (29.727 to 29.828) | 0.055 (-0.014 to 0.079) | 29.748 (29.648 to 29.835) | 6250 → 1 |
| `oversized-callback` (100,000, batches of 100,000) | 20.683 (20.622 to 20.683) | 0.064 (0.044 to 0.079) | 20.619 (20.542 to 20.622) | 1 → 1 |

For the two multi-callback 100,000-event stresses, baseline median growth was **23,196,176 bytes** (128-event batches) and **31,231,944 bytes** (16-event batches), versus **37,472** and **57,432 bytes** for the mailbox. Median *paired* reductions were **23,166,888** and **31,193,344 bytes** (22.094 and 29.748 MiB); every pair showed a reduction above 22.0 and 29.6 MiB, respectively. In the oversized single-callback case, baseline was **21,687,200 bytes** versus **66,992 bytes**, paired median savings **21,620,208 bytes** (20.619 MiB). Delivery counts dropped from **782 → 1** and **6,250 → 1** for the multi-batch stresses, and remained **1 → 1** for the oversized callback.

Controls and unfavorable differences are not omitted: the one-event paired median was **0 bytes**, with individual paired differences from **−4,096 to +4,112 bytes**; at exactly 4,096 events, the paired median was only **29,248 bytes** and the range included an **87,472-byte regression**. The 4,097-event overflow control had a **948,480-byte** median paired reduction, with the same all-root rescan outcome. Some signed candidate deltas in overflow/stress cases were negative because allocator state can shrink between samples. After-drain and after-stop growth measurements (including adverse results) are recorded verbatim in the summary and observations, not interpreted as isolated freed-task memory.

These results establish **bounded retained callback-task backlog under a synthetically stalled main actor**, not a bound on the peak memory of a native callback: native FSEvents conversion and its temporary path arrays are unchanged. Fixed mailbox startup allocation is excluded from the before-to-held growth measurement; this is not a complete per-monitor footprint, RSS, physical footprint, whole-player memory, throughput or latency result. One executing handler batch and one pending batch can coexist. Exceeding 4,096 queued events conservatively rescans all roots and may increase real filesystem work. The test was run once on one hosted runner image, with six balanced process pairs per case; other hardware, real workloads, and user-visible behavior remain unmeasured.

**Correction history:** [initial run 40634300332](https://github.com/Jagalite/illiquid/actions/runs/40634300332) rejected an immutable `weak var` test declaration with warnings-as-errors (corrected to `weak let`); an intermediate superseded run was cancelled; [run 40634770813](https://github.com/Jagalite/illiquid/actions/runs/40634770813) passed both test configurations but could not compile the benchmark due to missing Swift `-sdk`; [run 40642036115](https://github.com/Jagalite/illiquid/actions/runs/40642036115) also passed both suites but could not compile `Heap.c` without Clang `-isysroot`. Those unsuccessful receipts remain in `evidence/`; **none produced benchmark measurements**. Both SDK fixes are included in the successful exact tested revision above. The hosted runner did not have the shared Kyoto queue, so its isolated builds ran directly, serially, as specified by the workflow.

## Tradeoffs and scope

- Coalescing changes handler batch boundaries. The sole product consumer appends
  events to the existing debounce buffer; within-budget event content and order
  are preserved.
- Overflow deliberately exchanges detailed invalidation for a conservative
  all-root rescan, which can cause extra filesystem work in large libraries.
  This follows Apple's [event-loss recovery guidance](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html).
- Each callback takes a short lock around bounded bookkeeping. Normal-load
  throughput and interactive latency are not established by this memory study.
- Native callback conversion still allocates a temporary array and path strings.
  The handoff bounds retained backlog after callbacks return, not the peak
  allocation of one enormous native callback.
- While one batch is executing its synchronous handler, one further delivery may
  become pending. Restarted generations can also leave small, invalidated tasks
  queued, but stop releases their event data immediately.
- The existing 150 ms debounce and scan scheduling are unchanged. Sustained
  activity may still postpone invalidation; this change bounds the preceding
  task backlog.
- The component test and synthetic benchmark do not establish whole-player
  memory savings, live UI responsiveness, or audio/video playback performance.

This is a follow-up to [the sidebar debounce-buffer research](../../Documentation/FILESYSTEM_EVENT_BUFFER_MEMORY.md),
whose measurements explicitly excluded this earlier worker-to-main-actor boundary.
