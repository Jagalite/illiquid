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
