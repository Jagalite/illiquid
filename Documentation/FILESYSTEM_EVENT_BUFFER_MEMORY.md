# Bounded filesystem-event debounce retention

## Finding

Baseline: `af1c1add701e49b355448cf8983eaed1e7623108`.

`SourcesSidebar.enqueueFilesystemEvents` appended every delivered callback batch
to an array and restarted a 150 ms trailing debounce. A stream of callbacks with
no quiet interval could therefore retain an increasing number of event paths.
The debounce bounded how often invalidation ran, but did not bound its pending
input. This finding concerns the source browser while filesystem changes are
being delivered, rather than the player's video or audio decoding buffers.

## Change

`SourceFilesystemEventBuffer` retains ordinary events, in arrival order, up to
4,096 entries. A batch that would exceed that limit replaces the accumulated
detail with one `eventsDropped` marker. An incoming native loss marker takes the
same path immediately. Further batches cannot increase this buffer until it is
drained or cleared. Replacing the old array also releases its retained paths and
array storage when no other owner holds them.

The existing invalidation planner already maps `eventsDropped` to a full rescan
of every current watched root, independent of the marker's path. This preserves
the obligation to discover filesystem changes after detailed events are
discarded. It follows the same recovery principle as Apple's
[File System Events guidance](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html):
loss of event detail requires rescanning the monitored directories.

The sidebar uses the buffer's `take()` operation at the existing debounce
deadline. Watcher restart and sidebar teardown clear it at their existing reset
sites. The 150 ms scheduling policy and planner implementation are unchanged.

### Budget and tradeoff

4,096 is an internal event-count budget, chosen to preserve detailed ordinary
bursts while preventing a storm from retaining an unbounded path list. It is
not a byte limit or a platform-derived optimum. Path length and allocator
behavior determine the actual byte cost. No storage is allocated up front for
the limit.

Overflow deliberately trades precise invalidation for the existing conservative
all-root rescan. Large libraries may perform more subsequent filesystem work
than the original detailed plan would require. Repeated callbacks after
overflow share the same recovery obligation, so they do not enqueue additional
full-rescan markers in this buffer.

## Measurement

The reproducible driver is
[`Benchmarks/FilesystemEventBuffer/run.py`](../Benchmarks/FilesystemEventBuffer/run.py).
It compares the baseline sidebar's array accumulation operations with the new
production buffer, using fresh processes and balanced baseline/candidate order.
The actual production event and invalidation declarations are compiled without
platform stubs. Input batches have unique paths and leave scope before retained
heap is sampled.

The measurements distinguish three quantities:

- Buffer-owned event counts, including the observed maximum across callbacks.
- Retained path payload size, measured after the allocator sample.
- Live allocator bytes relative to a warmed empty-buffer sample. Linux uses
  `mallinfo2().uordblks + mallinfo2().hblkhd`; macOS uses
  `malloc_zone_statistics(NULL).size_in_use`.

These allocator measurements are neither RSS nor physical footprint. The driver
does not measure a live FSEvents stream, callback delivery latency, or the cost
of the full rescan after overflow.

### Results

Linux x86-64, Swift 6.3.2, optimized Swift 6 compilation. The experiment ran 56
fresh processes: seven workloads, four baseline/candidate pairs each, balanced
between AB and BA order. Paths were unique and 96–160 UTF-8 bytes long, delivered
in batches of 128. These are end-of-burst medians while the debounce is still
pending, before draining or rescanning:

| Delivered events | Baseline retained events | Candidate retained events | Baseline incremental live allocator bytes | Candidate incremental live allocator bytes |
| --- | ---: | ---: | ---: | ---: |
| 64 ordinary | 64 | 64 | 8,112 | 8,112 |
| 512 ordinary | 512 | 512 | 104,688 | 104,688 |
| 4,096 ordinary | 4,096 | 4,096 | 909,888 | 909,888 |
| 4,097 ordinary | 4,097 | 1 | 1,012,400 | 11,200 |
| 100,000 ordinary | 100,000 | 1 | 23,986,000 | 13,712 |
| 1,000,000 ordinary | 1,000,000 | 1 | 240,236,672 | 12,880 |
| 512 including a native loss marker | 512 | 1 | 104,688 | 0 net delta |

At one million delivered events, the measured retained allocator growth fell
from **229.11 MiB to 12.58 KiB**, a **99.9946% reduction** in this component
experiment. At 100,000 events it fell from **22.88 MiB to 13.39 KiB**. The ordinary
64-, 512-, and 4,096-event controls had identical allocator readings and retained
event/path counts for both variants.

The maximum candidate event count observed after callbacks was 4,096. After
overflow it retained one marker. **This is not a peak-memory measurement:** the
candidate first grows to its configured budget, and temporary input batches
are outside the sampled pending buffer. Likewise, the explicit-loss workload's
zero net delta means its allocator reading returned to the warmed baseline; it
does not mean that the marker occupies no memory.

One million events is a compressed stress input, not a measured real-world
event frequency. Timing is retained in the raw output for context, includes
path generation, and is not used to claim application CPU improvement.

Retained evidence:

- [Raw observations](../Benchmarks/FilesystemEventBuffer/evidence/linux/measurements.jsonl)
- [Summary](../Benchmarks/FilesystemEventBuffer/evidence/linux/summary.json)
- [Source receipts](../Benchmarks/FilesystemEventBuffer/evidence/linux/manifest.json)
- [Compiler and environment](../Benchmarks/FilesystemEventBuffer/evidence/linux/environment.json)
- [Parity verification](../Benchmarks/FilesystemEventBuffer/evidence/linux/verification.json)

## Correctness validation

`SourceFilesystemEventBufferTests` covers exact-capacity preservation, split and
single-callback overflow, native loss markers, continued storms, draining,
resetting, value-copy independence, current-root recovery, and configurable
limit boundaries. Seeded tests compare ordinary buffered events and planner
results against direct input; overflow tests require the existing all-root
recovery plan.

The Linux debug and release focused runs both passed **30 tests across three
suites**, including 800 generated within-capacity cases and 160 generated
overflow cases. Two selected limit regressions failed against a test-only
adapter of the original array operations, demonstrating that the tests detect
the previous unbounded behavior. The
[test receipts](../Benchmarks/FilesystemEventBuffer/evidence/linux/tests/README.md)
include the logs, adapter, commands, and exact tested source.

The benchmark independently verified exact equality of **14,079 events** across
ten within-capacity workloads, including paths, flags, order, and planner
results. Three explicit-loss cases preserved the same recovery plans, and
three overflow/drain/reset cases verified bounded admission and reuse.

The focused runner also executes the existing filesystem monitor/planner and
event-loss suites. The macOS workflow runs debug and release tests, the existing
planner parity validation, and the memory benchmark. The repository's normal
restoration workflow builds the app graph and runs the complete native release
suite, covering the SwiftUI integration as part of compilation.

## Limits

- The bound applies to the sidebar's pending debounce buffer. Native callback
  arrays and tasks awaiting main-actor delivery are separate allocations.
- Count bounds do not imply a fixed byte or process-memory bound.
- The trailing debounce can still postpone invalidation during uninterrupted
  activity; this change bounds retention during that wait.
- Full-rescan recovery uses the existing expansion-preserving cache invalidation
  path. Ordinary batches at or below the limit retain their previous event
  ordering and planner behavior.
