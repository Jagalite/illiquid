# Persistence writer lifetime review

Date: October 17, 2026. Baseline: `8c3cc3d4008d5d1b8d436bcf2d51d891382b6548`.
Subsystem: `IlliquidCore/Persistence`, not playback decoding, subtitles, media naming,
or renderer recovery. Visible open-PR changed paths were checked for overlap.

## Previous error-reporting hypothesis: not a defect for replacement snapshots

`PlaybackPersistenceStore` writes complete history and preferences snapshots to
separate destinations. A newer successful snapshot can legitimately supersede an
older failed attempt. Keeping that failure permanently sticky would misreport
recovery. Existing `PersistenceWriterTests` and `DeferredPersistenceWriterTests`
explicitly expect recovery after a later successful write.

The new regression suite checks both relevant schedules: an empty flush preserves
the previous error, while a newer pending snapshot can succeed after an in-flight
write fails. Error handling is unchanged; the replacement-snapshot contract is
now stated on the writer type. This writer is not an append-only operation log.

## Confirmed component defect: release of superseded requests under NSLock

`enqueue` previously assigned `pending = request` while holding its nonrecursive
lock. That assignment can destroy the old value or an object captured by the old
snapshot closure. If the object's `deinit` submits to the same writer, it attempts
to acquire the lock again and deadlocks. Cleanup that waits for a separate thread
to submit or flush can likewise block on the held lock.

Two standalone probes used the byte-identical production writer (Git blob
`59d0752a06762321caa62a14b99c333a121d9843`): one pending value containing a cleanup
object, and one pending snapshot closure capturing it. Both callbacks resubmitted
a newer value during destruction. Both debug and optimized baseline processes
stopped after entering `deinit` and were killed by a two-second watchdog. With the
fix, all four processes completed, wrote the newer value, and returned from flush.

The regression tests avoid permanently hanging CI: cleanup dispatches re-entry to
a separate queue and records whether it completed before a bounded wait expired.
On the original writer the wait expires; releasing the lock then allows the worker
to finish, so the test reports a normal assertion failure instead of hanging.

## Fix and review boundaries

Retain the superseded pending request in a local and use `withExtendedLifetime`
across `lock.unlock()`. This explicitly prevents an optimizing compiler from
releasing that request inside the critical section. It does not add asynchronous
cleanup, recursive locking, another queue, a changed debounce interval, or extra
snapshot capture. Replacement still happens under the lock, before cleanup can
submit a newer request; that newer request must not be overwritten on return.

The lifetime guarantee follows the [Swift standard-library documentation](https://docs.swift.org/latest/documentation/swift/withextendedlifetime%28_%3A_%3A%29-4mmpv/).
The relevant [deinitializer semantics](https://docs.swift.org/latest/documentation/the-swift-programming-language/declarations/)
explain why dropping the final reference can invoke cleanup code.

Review covered replacement linearization, value-to-snapshot and snapshot-to-value
transitions, release counts, reentrant submit/flush, an active blocked write,
retained laziness, and the unchanged latest-write error contract. This was a
self-review plus executed tests, not an independent-agent review.

## Executed validation

Environment: Swift 6.2.1, `x86_64-unknown-linux-gnu`, Swift 6 language mode.
The focused package copies the production source and repository test file without
rewrites or platform shims. Compiler warnings were treated as errors.

| Check | Baseline | Fixed |
| --- | --- | --- |
| Same-thread cleanup re-entry, value and snapshot, debug and optimized | Four watchdog timeouts | Four successful exits; newest value written |
| Bounded lifetime regression suite, debug | Eight lock-lifetime expectation failures | All 8 test functions / 14 expanded cases pass |
| Bounded lifetime regression suite, release | Eight lock-lifetime expectation failures | All 8 test functions / 14 expanded cases pass |
| Repeated full focused suite | Not used as a performance baseline | 20 debug + 20 release runs pass |
| Concurrent replacement/flush stress within repeated runs | Not a throughput benchmark | 4,000 submissions/run; 160,000 total; final marker and release counts preserved |

Reproduce the focused suite:

```sh
bash Scripts/test-persistence-writer-regressions.sh --configuration debug --jobs 2 -Xswiftc -warnings-as-errors
bash Scripts/test-persistence-writer-regressions.sh --configuration release --jobs 2 -Xswiftc -warnings-as-errors
```

The tests are also part of the normal `IlliquidCoreTests` target. A separate macOS
PR workflow runs the portable suite in debug and release without modifying the
shared restoration workflow or the native application dependency graph.

## Qualification limits

This is a confirmed production-component/API deadlock using synthetic Sendable
payloads and cleanup callbacks, not a reproduced visible macOS application freeze.
This investigation did not establish that the current history/preferences payload
types exercise the reentrant cleanup path in ordinary playback. Native macOS
execution and the complete application suite remain unverified locally; require
macOS CI before merging. No storage-durability, UI-latency, memory-saving, or
throughput improvement is claimed. Timer cancellation, debounce behavior, and
flush cancellation semantics were not changed or comprehensively qualified here.
