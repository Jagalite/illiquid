# Bound filesystem callback path materialization

## Finding and selected scope

Baseline: [`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`](https://github.com/Jagalite/illiquid/commit/ea2ff568237e2667f7b1aeee67b11a44ebe95b72).

The existing [debounce-buffer optimization](FILESYSTEM_EVENT_BUFFER_MEMORY.md)
bounds events after main-actor delivery. Upstream,
`NativeSourceFilesystemStream.receive` still reserves an array for the raw native
callback count and converts every nonnull C path to a Swift string. The resulting
array is captured by the task that delivers it to the main actor. For a callback
with more than 4,096 valid paths, the sidebar then immediately replaces all that
detail with one `eventsDropped` marker.

This investigation closes that per-callback allocation gap. It does not change
which filesystem updates the sidebar must discover or the existing rescan
policy. Repeated paths count as separate events under that policy; they are not
deduplicated before the limit is applied.

The concurrently opened [PR #118](https://github.com/Jagalite/illiquid/pull/118)
addresses queued main-actor delivery. This change is complementary: it bounds
the transient native callback arrays explicitly excluded from that PR's scope.

Apple documents that the non-CF callback supplies arrays of C strings owned by
the framework and deallocated after the callback returns. The new helper remains
synchronous and borrows these pointers only within the callback; no native
pointer escapes. See Apple's [FSEventStreamCallback contract](https://developer.apple.com/documentation/coreservices/fseventstreamcallback?language=objc)
and [event-loss recovery guidance](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html).

## Implementation and equivalence

`SourceFilesystemEventBatch.decode` shares the event buffer's existing default
limit. When the raw count exceeds 4,096 it first counts nonnull pointer entries.
The 4,097th valid entry proves that the downstream buffer would discard the
whole callback. The decoder returns that same recovery marker without reading
any of the C strings or flag entries.

If the preflight completes within the limit, only that many event slots are
reserved. An all-null oversized buffer returns immediately. Callbacks whose raw
count is at or below the limit skip preflight and retain one conversion pass.

The behavior argument has two cases:

- At most 4,096 valid paths: conversion produces the same paths, order and flags,
  including UTF-8 repair, empty strings and the existing handling of null slots.
  Downstream accumulation therefore receives identical events.
- More than 4,096 valid paths: both the original and candidate force the same
  all-root recovery in the default event buffer, regardless of its existing
  contents, flags, repeated paths or currently watched roots.

The native flag mapper, generation fences, task delivery and debounce timing
are unchanged. Loss flags on null path slots remain ignored. A large raw array
with many null entries must not be treated as overflow unless its valid count
actually exceeds the limit.

## Measurements

Linux x86-64, AMD EPYC 9V74, Swift 6.3.2. Release compilation uses Swift 6,
`-O -whole-module-optimization` and warnings as errors. Nine workloads ran in six
fresh-process baseline/candidate pairs each, in balanced AB/BA order: **108
measured processes**, plus calibration and verification. Each variant calibrates
its own fixed iteration count toward 60 ms because the overflow paths differ
by orders of magnitude.

Real, owned C strings are prepared before timing; measurement paths contain
128 UTF-8 bytes. Native-shaped pointer buffers and synthetic already-converted
flag values are identical between variants. The baseline loop is extracted from
frozen production source with checked SHA-256 and Git blob identities. The
candidate compiles the actual production helper and event policy. Both use the
same harness and flag-closure boundary. The CoreServices flag conversion itself
is outside this component measurement.

The allocator columns below measure growth while one decoded callback array is
alive, after warming the allocator and before inspecting the returned strings.
The time columns are median microseconds per callback, including array
construction and destruction. The final column is the median of **paired** time
changes, which need not equal the ratio of the two independent medians.

| Callback input | Baseline live allocator growth (bytes) | Candidate live allocator growth (bytes) | Baseline time (µs) | Candidate time (µs) | Median paired time change |
| --- | ---: | ---: | ---: | ---: | ---: |
| 64 valid | 12,528 | 12,528 | 4.16 | 3.93 | -2.81% |
| 512 valid | 109,296 | 109,296 | 31.13 | 34.19 | +4.35% |
| 4,096 valid | 883,440 | 883,440 | 397.17 | 412.33 | -2.33% |
| 4,097 valid | 883,648 | 0 | 423.59 | 3.06 | -99.30% |
| 100,000 valid | 21,598,704 | 0 | 13,297.34 | 2.57 | -99.98% |
| 1,000,000 valid | 215,998,704 | 0 | 132,278.95 | 2.59 | -99.9980% |
| 8,192 slots / 4,096 valid | 981,744 | 883,440 | 424.28 | 391.71 | -5.65% |
| 100,000 slots / 1 valid | 2,400,048 | 0 | 42.29 | 124.43 | +184.72% |
| 100,000 null slots | 2,400,048 | 0 | 37.97 | 59.64 | +70.49% |

The 100,000-path case avoids **20.60 MiB** of measured callback-owned allocator
growth; the million-path stress case avoids **205.99 MiB**. Each oversized
candidate returns one event containing the one-byte marker path instead of
retaining the input-sized event array and path copies. It reads no flag entries.

A zero allocator delta is the observed change relative to the warmed process,
not a claim that the marker or the sparse one-event result has no storage.
These are live allocator-accounted
bytes, not peak memory, RSS, physical footprint or total player-memory savings.
FSEvents-owned input storage is outside the delta and remains present during the
callback. The million-path case is synthetic stress, not an observed event rate.

### Timing tradeoffs

This is a memory-boundary improvement with a large speedup for callbacks that
already exceed the existing budget. It is not a universal CPU speedup. The
ordinary 64/512-event controls had median paired changes of -2.81%/+4.35%; the
4,096-event boundary had -2.33%. Individual pairs varied in both directions;
all samples and ranges are retained.

Sparse arrays with at most 4,096 valid entries require preflight plus conversion
and can be slower. The 100,000-slot/one-valid-path stress case rose from 42.29 µs
to 124.43 µs while avoiding a 2,400,048-byte reservation. The all-null case also
showed higher service time despite its early return. These costs are reported,
not treated as normal-input improvements. No end-to-end UI or playback latency
claim follows from these component timings.

## Correctness and integration

The differential experiment passes **17 cases in both debug and optimized
builds**, comparing exact detailed callbacks within the limit and exact buffered
events and invalidation plans for every case. Four overflow cases verify the
single-marker result and zero flag reads. Cases include all flag kinds, ignored
null-slot loss flags, reported loss at different positions, malformed UTF-8,
embedded NUL, Unicode, duplicates, sparse arrays and no watched roots.

The focused regression suites pass **40 tests in four suites in both debug
and release**, with compiler warnings treated as errors. The new durable
`SourceFilesystemEventBatchTests` exercise pointer lifetime, exact boundary and
sparse-input behavior, and 162 seeded comparisons of the helper composed with
the buffer and planner. As a negative control, the overflow test was compiled
against the extracted original decoder: it failed the event-count, recovery-marker
and zero-flag-read expectations for both 4,097 and 8,192 paths, as expected. The focused filesystem
regression script includes the new source and tests. The macOS volume-regression
script also includes the helper when compiling the actual native adapter; its
existing lifecycle tests exercise live FSEvents delivery and stale-generation
rejection. The event-loss workflow runs debug/release regressions and the same
benchmark. The repository's normal restoration workflow builds the full app
graph and runs the native release suite.

Local validation is component-level on Linux. The macOS Kyoto queue and Apple
frameworks are unavailable in this environment, so these direct isolated builds
do not qualify native FSEvents behavior, the complete app or live playback.

## Remaining boundary

The new limit bounds one materialized callback. It does not bound the number of
small callbacks queued for main-actor delivery, native input memory, path byte
length or rescan work. The sidebar's accumulated debounce buffer remains
responsible for overflow across several callbacks. No additional rescan is
introduced by this change under that existing default policy.

## Reproduction and evidence

See [benchmark instructions](../Benchmarks/FilesystemEventBatch/README.md).
Retained evidence includes:

- [Summary](../Benchmarks/FilesystemEventBatch/evidence/linux/summary.json) and
  [all 108 observations](../Benchmarks/FilesystemEventBatch/evidence/linux/observations.jsonl).
- [Calibration](../Benchmarks/FilesystemEventBatch/evidence/linux/calibration.json),
  [environment](../Benchmarks/FilesystemEventBatch/evidence/linux/environment.json) and
  [source/compiler receipts](../Benchmarks/FilesystemEventBatch/evidence/linux/manifest.json).
- [Verification receipts](../Benchmarks/FilesystemEventBatch/evidence/linux/verification.json),
  with compressed exact debug/release traces beside them.
- [Commands](../Benchmarks/FilesystemEventBatch/evidence/linux/commands.jsonl) and
  [completion/source-identity check](../Benchmarks/FilesystemEventBatch/evidence/linux/completion.json).
- Focused regression [debug log](../Benchmarks/FilesystemEventBatch/evidence/tests/debug.log),
  [release log](../Benchmarks/FilesystemEventBatch/evidence/tests/release.log),
  [commands](../Benchmarks/FilesystemEventBatch/evidence/tests/commands.json) and
  [source hashes](../Benchmarks/FilesystemEventBatch/evidence/tests/manifest.json).
- Original-decoder [negative-control result](../Benchmarks/FilesystemEventBatch/evidence/tests/negative-control.json)
  and [expected assertion failures](../Benchmarks/FilesystemEventBatch/evidence/tests/negative-control.log).
