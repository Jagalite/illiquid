# Filesystem notification delivery memory

This research closes an unbounded retention point **before** the sidebar's
existing bounded debounce buffer. When MainActor is busy, the original monitor
creates one task per filesystem callback. Every task retains its callback's
complete event array until it can execute. The downstream 4,096-event buffer
cannot limit these waiting tasks.

The change gives each watch session a
[`SourceFilesystemEventDelivery`](../../Sources/IlliquidApp/UI/SourceFilesystemEventDelivery.swift).
It stores pending events in the existing `SourceFilesystemEventBuffer` and
schedules a MainActor task only when an idle delivery first receives work.
The task weakly references the delivery object and never captures a callback
array. The monitor closes that delivery on stop, replacement, and deallocation.

## Results

The final Linux x86_64 / Swift 6.3.2 run observed:

| Input events | Batch size | Baseline bytes | Mailbox bytes | Baseline deliveries | Mailbox deliveries |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 64 | 128 | 17,440 | 17,488 | 1 | 1 |
| 512 | 128 | 118,544 | 113,968 | 4 | 1 |
| 4,096 | 128 | 968,544 | 918,720 | 32 | 1 |
| 4,097 | 128 | 970,432 | 25,408 | 33 | 1 |
| 100,000 | 128 | 24,677,824 | 23,296 | 782 | 1 |
| 1,000,000 | 128 | 256,110,960 | 29,232 | 7,813 | 1 |
| 100,000 | 100,000 | 23,416,144 | 22,480 | 1 | 1 |
| 512 (one loss marker) | 128 | 118,544 | 10,080 | 4 | 1 |

For 100,000 events in 128-event batches, the median pending-memory delta fell
from **23.53 MiB to 22.75 KiB (99.91%)**, and deliveries fell from **782 to 1**.
At one million events, it fell from **244.25 MiB to 28.55 KiB (99.99%)**,
with **7,813 deliveries reduced to 1**.

Closing at the 4,096-event boundary released **895,504 bytes**
immediately in the mailbox implementation while MainActor remained occupied.
The original implementation released **0 bytes** at close because its waiting
tasks still owned their arrays. Both objects remained alive during the samples.


These are live **allocator-accounted component bytes**, not player RSS or
physical footprint. Four fresh-process baseline/candidate pairs are used for
each workload, with balanced AB/BA order. A count of one million is a synthetic
stress input, not a measured filesystem event frequency or a claimed normal
application workload. No playback frame-rate, latency, or CPU improvement is
claimed.

The 64-event control deliberately retains the same event detail and schedules
one task in both versions. The mailbox adds a small amount of bookkeeping.
Larger below-limit bursts save task allocations; overload cases discard detail
in favor of conservative recovery.

## Behavior and ownership

- Up to 4,096 pending events retain their exact paths, flags, and arrival order.
  Multiple native callbacks may be combined into one handler invocation.
- Overflow or an explicit native event-loss marker replaces detail with one
  `eventsDropped` event. The existing planner then rescans every watched root.
  This trades targeted invalidation for potentially more filesystem work.
- Only one delivery task waits for MainActor per live watch session. A producer
  can schedule the next task once a drain has taken the current batch; the
  current synchronous handler may still be processing that drained batch.
- Stop clears pending event references immediately, even while MainActor has
  not run the queued task. Late callbacks can only reach the permanently closed
  delivery from their original session. The monitor also retains its generation
  guard.
- Buffer admission and the scheduled flag change under one lock. The handler
  and task scheduling execute outside that lock. Reentrant sends and concurrent
  producer/drain activity cannot strand accepted work.

The bound covers the pending mailbox, not every event in the process. One
drained batch, a new pending buffer, the sidebar's own buffer, and the transient
native callback array can coexist. Old closed sessions may leave small weak
delivery tasks queued until MainActor runs them. The limit counts events rather
than UTF-8 bytes; path lengths still affect memory. Native FSEvents allocation
and initial conversion of a large callback array are unchanged.

The sole production handler in `SourcesSidebar` appends notifications to its
debounce buffer and resets a 150 ms trailing timer. It does not rely on native
callback boundaries. Coalescing occurs only for callbacks already waiting to be
delivered; there is no new timer or delay.

## What the experiment executes

1. `baseline/SourceFilesystemMonitor.swift` is the exact production file at
   commit `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`. Its SHA-256 and Git blob
   identity are checked against `baseline/manifest.json` before compilation.
2. The runner extracts the original per-callback Task body verbatim into a
   small adapter representing one active watch revision. Native stream creation,
   notification registration, and the monitor facade are outside the component
   measurement. The candidate compiles the complete production delivery class.
3. Both variants compile the same current production event buffer and planner.
   Foundation, Swift concurrency, and allocation are real on both Linux and
   macOS; no platform behavior is stubbed.
4. The MainActor harness synchronously waits while a separate dispatch queue
   produces unique paths in batches. Each temporary batch leaves its scope
   before that worker signals completion. macOS also drains its per-batch
   autorelease pool. The recorder is asserted empty before memory is sampled.
5. The allocator is sampled before input and again while delivery tasks remain
   queued. Only after the sample does MainActor drain and verify delivered
   events, batch counts, and recovery plans. Output construction and plan
   validation therefore do not inflate the pending-memory sample.
6. A separate close experiment holds MainActor continuously across `close()` and
   samples again. It measures immediate payload release without giving queued
   tasks an opportunity to run. Lifecycle tests separately check suppression
   of obsolete deliveries.

The allocator helper is reused unchanged from
`Benchmarks/RuntimeLeaseHistory/CLeaseHeap`: Linux reports
`mallinfo2().uordblks + mallinfo2().hblkhd`; macOS reports
`malloc_zone_statistics(NULL).size_in_use`. Runtime allocations and allocator
caches can contribute to the delta. It is not an exact sum of object sizes.
The delivered-event and task/batch counts provide a separate deterministic
observation of the ownership mechanism.

## Correctness checks

The component experiment compiles debug and optimized binaries with Swift 6
checking and warnings treated as errors. It compares complete ordinary event
transcripts and planner outputs at 1, 63, 129, and 4,096 events, checks equivalent
all-root recovery for explicit event loss, and checks conservative recovery at
4,097 and 10,000 events. Each delivery workload also verifies its delivered
payload and number of handler invocations.

`SourceFilesystemEventDeliveryTests` adds boundary and overflow parameterizations,
all flag bits and Unicode paths, close/replacement isolation, weak task
ownership, reentrant sends, and concurrent producers/drains with no lost or
duplicated events and preserved per-producer order. On Linux, the isolated debug
and release runs each passed 19 test functions across the delivery and existing
volume-policy suites; logs and source hashes are retained with the evidence.

On macOS, `Scripts/test-source-volume-regressions.sh` additionally compiles the
real AppKit/FSEvents monitor. Its lifecycle suite covers startup reconciliation,
blocked native creation, failed creation, stop, replacement, actual native
notification delivery, and deallocation. This PR adds held-MainActor tests for
coalescing, overflow, and replacing a watcher with a pending backlog.

The `Source volume regressions` workflow runs those debug/release checks and
the same paired benchmark on macOS. It uploads native component evidence as
`filesystem-event-delivery-memory`. These focused checks do not build or qualify
the full player UI or native playback graph.

## Reproduce

```sh
python3 Benchmarks/FilesystemEventDelivery/run.py \
  --output /tmp/illiquid-filesystem-delivery --pairs 4
bash Scripts/test-source-volume-regressions.sh --jobs 2 -Xswiftc -warnings-as-errors
bash Scripts/test-source-volume-regressions.sh -c release --jobs 2 -Xswiftc -warnings-as-errors
```

Use a new output directory and Swift 6.1 or later on `PATH`, or pass
`--swiftc /path/to/swiftc`. The test script submits builds to Kyoto when available.
Submit the benchmark command through Kyoto too on the shared development host;
the hosted workflow does this automatically. The recorded Linux workspace has
no Kyoto queue, so its isolated builds ran directly and serially.

`OUTPUT/evidence/` contains compiler/source/executable hashes, exact-comparison
receipts, raw observations, command/build logs, close observations, summaries,
and a final completion receipt. Compiler products remain under `OUTPUT/build/`.
The committed `evidence/linux/` directory contains the successful final run and
the isolated test receipts.
