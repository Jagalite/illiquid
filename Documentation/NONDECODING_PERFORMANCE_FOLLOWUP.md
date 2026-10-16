# Illiquid: non-decoding performance research — follow-up

**Date:** October 15, 2026, America/New_York.
**Repository baseline:** `854f8365750a0e4f046ab7015e01ca7a138ada40`.
**Status:** implemented and component-tested candidate; native macOS build, app traces and release qualification remain outstanding. No remote commit or pull request was created.
**Relationship to the first pass:** cumulative delivery retains the ranking/cache changes and original evidence in `NONDECODING_PERFORMANCE_INVESTIGATION.md`. This document reports new work only.

## Executive findings

Two hypotheses from the first report are now supported by experiments, with implementations included.

**History coalescing was occurring too late to avoid copy-on-write amplification.** The store retained a value snapshot on every mutation. The following mutation could copy large dictionaries before the writer discarded the previous pending snapshot. The candidate coalesces capture requests, taking a synchronized value snapshot only when the writer is ready to invoke its callback. The original eager-submission API remains available to existing clients.

With the actual production history store and real Foundation types, a 100-update burst against 100,000 history entries fell from **1,090.947 ms to 0.840 ms** in mutation-only time. Including the final flush, the median fell from **2,356.418 ms to 721.260 ms**. Those are different metrics: the write is not skipped or made magically instantaneous. Smaller histories improve too. Flush-after-every-update controls have essentially unchanged total time and a small increase in mutation overhead.

**A resident preview could wait behind unrelated disk-actor work.** The existing foreground-promotion path awaited that actor before returning its already-resident image. The new path reserves bounded metadata protection synchronously, queues one utility drainer, and returns without that await when admission succeeds. A controlled 500 ms actor stall produced **500.611 → 0.114 ms** median image-return time. This is an injected dependency test, not a measured 500 ms filesystem problem in a running Mac app.

The new work includes **364 completed timing/allocation observations**, real-core persistence tests, deterministic persistence comparison, mailbox concurrency tests, portable cache/disk integration checks, and additional opt-in profiling intervals. It does not touch video decoding, rendering quality, audio/subtitle output, refresh rate, cache budgets, or checkpoint cadence.

## 1. What was tried and decided

| ID | Experiment / design question | Result | Disposition |
| --- | --- | --- | --- |
| E07 | Does eager pending snapshot capture amplify copying? | Exact writer plus two-dictionary kernel: 101 captures collapse to one pending capture or two with an in-flight write. | Confirmed; implement deferred capture. |
| E08 | Does this matter in the real persistence store? | 126 observations across 1k/10k/100k histories, burst, blocked set, and flush-per-update controls. | Implemented; retain schema, admission guards, eager API and flush/error behavior. |
| E09 | Are allocations actually removed? | Separate kernel allocator runs show 200 copy-allocation requests disappear before draining, or fall to two during a blocked write. | Confirmed for the measured allocator scope; not an RSS finding. |
| E10 | Does disk housekeeping delay a RAM hit? | Existing path waits for injected 100/500 ms actor blockage; reserved path returns before release. | Implemented with bounded reservations and fallback. |
| E11 | Can queued promotion preserve protection under reordering? | Mailbox races, real disk-state tests with image adapters, pending encoding, overflow and clear coverage. | Candidate passes component tests; native framework tests still required. |
| E12 | Does effective persisted behavior match? | 200 reload receipts match after 10,000 deterministic mixed operations per variant. | Passed, with documented normalization of an obsolete duplicate preferences field. |
| D01 | Simply launch an unbounded task for each promotion | Reviewed at design level, not benchmarked as an implementation. Actor jobs are not FIFO [A1]; queue growth and eviction ordering would become unclear. | Rejected in favor of an explicit bounded handoff. |
| D02 | Encode history under the store lock to avoid copies | Reviewed, not trialed. It would block reads/mutations for the entire encoding/write interval. | Rejected. |
| D03 | Compare the entire history for equality on every update | Reviewed, not trialed. This adds history-sized work to the hot path. | Not selected; per-field no-op guards remain a smaller future experiment. |
| D04 | Replace persistence with SQLite immediately | No database migration implemented or benchmarked. Full-history encoding/loading remains expensive. | Next architectural investigation, with migration/recovery gates. |
| D05 | Direct disk lookup before full inventory | Instrumentation added; no direct-lookup/index rewrite trial. | Still open. |

Design-level rejections are not counted as failed performance experiments.

## 2. Environment and measurement discipline

The environment is **Linux x86-64, AMD EPYC 9V74, Swift 6.2.1, glibc 2.41**. Optimized harnesses use `swiftc -O -swift-version 6 -warnings-as-errors`. The host is shared, not quiesced or thermally controlled. Foundation and allocator behavior differ on macOS; numerical ratios are not portable promises.

Each formal workload/variant uses seven fresh processes, alternating baseline/candidate and candidate/baseline order by round. Timing drivers ran serially, with compilation between phases rather than concurrently with timed binaries. Inputs are synthetic and isolated; no installed app data or user media was accessed or modified. No outliers were removed. Preliminary trials and failed execution-launch attempts are not part of the formal receipts.

The counts are 126 full-store observations, 84 writer-kernel timing observations, 84 separately metered kernel observations, and 70 preview observations. Medians summarize process-level observations, not p95/p99 application interaction latency. Every raw observation, command result, source manifest and binary hash is retained in the follow-up evidence directory. No compiled binaries are needed in the delivery bundle.

Persistence baselines are exact original Git blobs. The preview baseline uses the first pass's cache candidate plus the unchanged original disk actor, preventing its existing hexadecimal/admission improvements from being credited again. This is a selected-source experiment, **not a full repository checkout/build**. Real macOS CGImage/ImageIO, Instruments, UI drawing, physical footprint, GPU and energy were not measured.

## 3. History: coalesce before capturing large value snapshots

### Mechanism and implementation

The original `PlaybackPersistenceStore.mutate` locks its state, performs a mutation, then calls `historyWriter.submit(state)`. The writer retains that value as its latest pending snapshot. Because Swift dictionaries use copy-on-write, a subsequent mutation may have to copy buffers still shared with the pending or in-flight value. Replacing the pending snapshot afterward cannot undo the copy/deallocation work already incurred.

`CoalescingPersistenceWriter.submitSnapshot` adds a separate, explicit API for a synchronized snapshot factory. The store submits a closure that captures the store owner, not its dictionary value. The queue replaces pending factories just as it already replaced pending values. Once ready to write, it extracts the factory under the writer lock, releases that lock, obtains a short-lived store lock to capture a value, releases the store lock, and only then encodes and calls the destination.

The order matters. Snapshot capture never holds the writer lock while acquiring the store lock, so the mutation path's store-lock → writer-lock sequence does not create a lock inversion. Encoding and I/O never run while holding the store lock. An in-flight write still owns an immutable value, and a later mutation may still require one copy; this change does not sacrifice isolation to eliminate that necessary copy.

Only the history store opts into deferred capture. Existing `submit(value)` clients, including separate session-checkpoint work, retain eager capture semantics. The 100 ms writer delay is unchanged. The factory may include newer accepted mutations before capture; it does not promise a value frozen at submission. Strong owner capture keeps the store alive until a pending write is superseded/drained; lifetime behavior is tested.

Unreadable-history protection, disabled-history admission, explicit clearing, content-version history, sticky completion, latest-pending ordering, error propagation and final flush remain in place. The history JSON schema and preference keys are unchanged. No partially hydrated store or new storage migration is introduced.

### Actual store: 100-update bursts

Seed creation, initial loading, and path warmup are outside mutation timing. These fixtures contain two dictionaries with 1,000, 10,000 or 100,000 synthetic media paths. Each update assigns a new position and the same duration through the production `setPlaybackProgress`. The default production writer delay is used. Both variants reload successfully with the final position and the original number of records.

All times below are medians across seven processes:

| History entries | Before: 100 updates | After: 100 updates | Before: updates + final flush | After: updates + final flush |
| ---: | ---: | ---: | ---: | ---: |
| 1,000 | 2.676 ms | 0.760 ms | 9.612 ms | 7.947 ms |
| 10,000 | 25.694 ms | 0.915 ms | 95.328 ms | 70.228 ms |
| 100,000 | 1,090.947 ms | 0.840 ms | 2,356.418 ms | 721.260 ms |

At 100,000 entries the slower baseline loop overlaps writer activity and produces three history-set callbacks in the median run, versus one in the candidate. At 1k and 10k both variants produce one. The end-to-end improvement therefore includes better effective coalescing; it is not solely an encoding speed comparison.

This is a stress workload, not a claim that normal playback performs 100 checkpoints in a millisecond. Inspection of `PlaybackController` shows its position-event checkpoint condition uses a roughly ten-second position delta [S3]. Burst, rapid interaction and blocked-writer cases must be distinguished from routine steady playback. The full-store harness does not execute the controller or SwiftUI.

### Actual store: blocked destination callback

The test gates one actual `UserDefaults.set` call after its JSON encoding, performs 100 more updates, releases the gate, flushes and reloads. It exercises in-flight snapshot retention and latest-state ordering. It does not emulate filesystem cancellation on a NAS.

| History entries | Before: 100 updates | After: 100 updates | Before: updates + final flush | After: updates + final flush |
| ---: | ---: | ---: | ---: | ---: |
| 1,000 | 3.012 ms | 0.608 ms | 14.481 ms | 11.410 ms |
| 10,000 | 25.424 ms | 0.868 ms | 136.112 ms | 120.538 ms |
| 100,000 | 1,171.954 ms | 8.800 ms | 2,369.021 ms | 1,194.745 ms |

Both variants invoke two history-set callbacks in this scenario: the initial write and the latest pending write. The candidate still pays the first copy needed to preserve the in-flight value. At 100k, 8.800 ms of total mutation work remains; this is not a guarantee that every individual update is under a frame budget.

### Negative/control result: flush after every update

The control performs five updates, completing a flush after each. It intentionally prevents pending-copy amplification. End-to-end times include all five flushes:

| History entries | Before: five updates + five flushes | After: five updates + five flushes | Before → after: mutation-only total |
| ---: | ---: | ---: | ---: |
| 1,000 | 32.431 ms | 32.611 ms | 0.291 → 0.423 ms |
| 10,000 | 342.558 ms | 338.196 ms | 0.453 → 0.710 ms |
| 100,000 | 3,707.691 ms | 3,690.567 ms | 0.485 → 0.664 ms |

There is no established meaningful end-to-end improvement in this control. Mutation-only time is slightly worse in the candidate, approximately 0.13–0.26 ms extra across five calls in these runs. The extra factory/handoff is not free. This is evidence for selecting the change to prevent burst amplification, not marketing it as faster in every usage pattern. Full-history encoding and the defaults callback still dominate this case.

### Durability boundary

`flush` waits for the writer's queued callbacks and reports their errors. Here the callback encodes JSON and invokes `UserDefaults.set`; the code does not perform a filesystem durability barrier or prove persistence through sudden power loss. Successful in-process reloads do not establish crash durability. This clarifies the word “flush” without weakening the pre-existing implementation. Final required callbacks are still awaited; they are not discarded to improve a timing result.

## 4. Memory: verified allocation traffic, not claimed resident savings

The separate writer kernel uses the exact writer implementations with the store's original locking/two-dictionary mutation pattern. A deliberately long 60-second delay in its pending case prevents background draining until the explicit flush. This is **not** a production delay change. The blocked case retains one immutable value inside a gated callback. Key construction and fixture creation are outside the measured loop; this is not the full store's URL-normalization path.

For 100 measured mutations at 100,000 entries:

| Kernel condition, 100k entries | Snapshot captures: before → after | Malloc-family requests: before → after | Requested bytes: before → after |
| --- | ---: | ---: | ---: |
| pending | 101 → 1 | 200 → 0 | 1,264,857,600 → 0 |
| blocked | 101 → 2 | 200 → 2 | 1,264,857,600 → 12,648,576 |

The pending case measured zero malloc-family requests in the candidate mutation loop; the blocked case removes 99% of those requested bytes. At 1k/10k the same structural counts appear: 200 → 0 requests before draining, and 200 → 2 with an in-flight write. This supports the identified mechanism rather than merely a favorable wall-clock observation.

Unmetered kernel timing at 100k is 740.717 → 0.027 ms for pending updates, and 770.865 → 10.724 ms for updates while a write is blocked. These kernel values deliberately exclude real-store normalization and must not replace the full-store table.

The Linux meter counts successful `malloc`, `calloc` and `realloc` requests and sums requested sizes during the loop. It does not subtract frees, capture every allocator family or virtual mapping, or measure live/peak heap, RSS, macOS physical footprint, compressed memory or GPU storage. **1,264,857,600 fewer requested bytes is not 1.26 GB less resident app RAM.** The history remains loaded, and serialization buffers still exist. On-device allocation generations and physical footprint remain necessary.

## 5. Foreground previews: remove a disk dependency from accepted resident hits

### The path being changed

A foreground request finding a resident image updates its RAM priority, but previously awaited `disk.promote` when converting a background resident or refreshing its disk touch. Any synchronous work already occupying the disk actor could delay delivery of that resident image. RAM access and disk housekeeping were therefore not independent on this path.

The candidate performs a bounded synchronous reservation before scheduling metadata promotion. Successful reservation permits immediate image return without waiting for that actor. The reservation is not merely “fire and forget”: it participates in background disk eviction decisions until the actor has processed it. A normal already-foreground/recently-touched hit follows the existing fast path.

### Safety and boundedness

The new `ThumbnailPromotionMailbox` holds at most **128 distinct pending digests**, coalesces duplicates, and starts at most one drainer. Its small lock protects metadata only, never hashing, disk I/O or an await. A drainer yields after eight acknowledgements so a long batch does not monopolize the actor between I/O operations.

A claim remains protected while being processed, not just until dequeued. In-flight encoding latches promotion before its disk entry commits. Background eviction and reservation have a defined ordering: if reservation wins, speculative eviction skips the entry; if eviction has already begun, the new request uses the existing awaited path. Epoch reset discards obsolete requests, and a stale acknowledgement cannot delete a new epoch's protection. Pending image writes remain separately bounded as before.

**Saturation, epoch mismatch and already-started eviction deliberately fall back to the prior awaited promotion path.** This is not an unconditional zero-wait guarantee for every possible resident hit. Foreground requests and explicit cache reconfiguration/clearing retain their existing eviction authority. Promotion/rename failures remain best-effort cache behavior, not an asserted new persistent-storage guarantee. Canceled requests retain the prior cancellation check on the promotion path.

Swift actors serialize their isolated work but do not promise FIFO ordering of queued jobs [A1]. The reservation is necessary to avoid treating task creation order as eviction protection. The added synchronization is reviewable in a small Foundation-only component rather than an unbounded stream of detached tasks.

### Controlled latency results

The harness first populates a resident image and disk entry, then optionally holds the disk actor with a semaphore. The 100/500 ms values are injected blockage durations, not observed real storage latencies. It measures the existing-key cache call through return of the resident image. Constructor work, file identity lookup, preview extraction and UI rendering are outside this interval.

| Resident-hit case | Before median (min–max) | After median (min–max) |
| --- | ---: | ---: |
| Promotion, no injected stall | 0.198 (0.123–0.273) ms | 0.115 (0.057–0.510) ms |
| Promotion, disk actor blocked 100 ms | 100.518 (100.461–100.608) ms | 0.100 (0.087–0.147) ms |
| Promotion, disk actor blocked 500 ms | 500.611 (500.519–500.828) ms | 0.114 (0.068–0.338) ms |
| Already-foreground control, disk blocked 100 ms | 0.049 (0.034–0.071) ms | 0.060 (0.037–0.205) ms |
| Already-foreground control, disk blocked 500 ms | 0.067 (0.029–0.110) ms | 0.030 (0.023–0.046) ms |

Every tested promoted hit is foreground on disk after the explicit test flush. All 14 candidate blocked-promotion samples return before the disk gate opens; all corresponding baseline samples wait for release. Already-foreground controls return before release in both variants. Their small timing differences are mixed and should not be sold as a universal hot-hit speedup. The unblocked candidate's maximum is worse despite its lower median; seven samples do not establish a tail-latency guarantee.

### What these preview tests do and do not exercise

The portable runner compiles the cache/disk actor bodies and actual mailbox with explicit adapters for CGImage pixels, JPEG/ImageIO routines and unused file-identity helpers. It uses real Foundation filesystem operations and real SHA-256 via OpenSSL on Linux. Actor state, epoch checks, promotion, background eviction, capacity and physical-writer handoff remain the production logic.

The test payloads are a header and padding, **not JPEGs**. Native image allocation, ImageIO corruption handling, OS memory-pressure delivery, actual slow filesystems and visible hover rendering remain unqualified. The existing disk read/codec checks are not replaced in shipped source. The four new macOS-native counterpart tests use actual CoreGraphics/ImageIO but were only syntax-parsed here.

Cold disk cache lookup still inventories the cache directory. That operation remains actor-serialized and may block. File-identity checks still occur through the existing reader before a real hover request reaches this cache call. No new claim is made about cold preview latency or complete input-to-photon time.

## 6. Regression evidence and implementation review

- **12 actual-core XCTest tests passed in both release and debug.** They cover factory coalescing, the eager API, writer-lock release before snapshot capture, blocked immutable snapshots, final flush ordering, write-error recovery, asynchronous flush, concurrent submissions, reload, completion/version history, explicit clearing, disabled history, unreadable data and owner lifetime. Repeated configurations are not counted as distinct test cases.
- **Five actual-mailbox XCTest tests passed**, including 5,000 concurrent reserve-versus-evict races, duplicate/capacity behavior, acknowledgement/reset and flush waiting. These are synchronization regressions, not a formal proof of every scheduler interleaving.
- **200 effective reload-state receipts match** after 10,000 mixed operations per variant through the actual store and JSON. Completed-file set ordering is normalized. The obsolete preferences copy embedded in history is replaced by effective reloaded preferences for comparison: the separate preference key has precedence, and deferred capture can record that duplicate later. The comparison does not assert JSON byte identity or equal callback counts.
- **196 candidate portable preview checks pass**, plus five baseline checks. Coverage includes 30 eviction/protection trials, promotion during suspended encoding, a full 128-entry handoff, stale-epoch clearing and disk reload after resident pressure. Image-framework behavior is explicitly adapted.
- **The first-pass regressions were rerun:** 4,218 ranking comparisons, 1,868 candidate cache/hex checks and 1,960 identical cache decision/survivor trace rows. The previous disk-free stub only gained the new handoff API signatures; queued-promotion behavior is tested separately by the follow-up suite.

These counts overlap in purpose and are not a single additive “total tests” score. Portable production components compile with Swift 6 warnings treated as errors in timing/differential harnesses. Four new native framework tests and changed native source files pass syntax parsing only. The full SwiftPM app graph, complete native/app test suites, architecture checker, bundle/signature build, Instruments and live PiP/sleep/resize/hover tests were not run.

The implementation review specifically retained value-snapshot isolation, prevented store/writer lock inversion, kept reservations until acknowledgement, added an eviction-versus-reservation boundary, kept overflow fallback, and preserved epoch/cancellation checks. No GitHub workflow, dependency version, permissions, installed preferences or media was modified.

## 7. Instrumentation and next experiments

New markers separate `HistoryMutation` (including store-lock wait), `HistorySnapshot`, `HistoryEncode`, `HistoryDefaultsSet`, `HistoryFlush`, and a `HistoryPayload` byte event. Preview markers separate `ThumbnailResidentHit`, `ThumbnailPromotionReserve`, `ThumbnailDiskPromotion`, first `ThumbnailDiskInventory`, and `ThumbnailDiskRead`. Earlier admission/pressure/resident-byte markers remain.

They require the isolated benchmark bundle ID and both explicit opt-ins documented in the benchmark README. There are no per-frame timers, accumulated sample arrays, stderr writes or media-path payloads in the helper. Disabled calls still have small function/branch overhead; “disabled” does not mean literally zero instructions. The macOS signposter branch needs native compilation and a trace check. Resource baselines should run with instrumentation off; diagnostic traces should be separate.

**Next priority: actual Mac qualification of the two candidates.** Use matched release bundles on Apple hardware, the same production policies, fixed fixture/cache/history state and identical window dimensions. Measure steady playback separately from rapid scrub/source-change bursts. Compare total app footprint and allocation generations; prove no additional idle wakeups. Trace controller-to-history calls rather than infer their frequency from this stress harness. Apple recommends identifying main-thread work and avoiding unnecessary synchronization with background work [A2].

**Next architecture target: full-history serialization and loading.** At 100k entries a candidate burst still writes a roughly 9.25 MB JSON payload, and the final callback remains hundreds of milliseconds in this environment. Deferred capture does not solve history-proportional encoding or initial loading. Test per-field no-op guards to avoid copying an unchanged duration map during an in-flight write, then compare dirty-record/batched storage against the current whole-file path. A SQLite/transactional design must preserve completion/version archives, unreadable-history recovery, preferences precedence, interrupted migration, clear semantics and final-checkpoint ordering. Apple's guidance supports reducing frequent whole-document serialization, but is not performance evidence for an unimplemented migration [A3].

**Next preview target: cold inventory and first disk access.** Measure empty, 1k, 8k and oversized disposable caches, malformed names/duplicate digests, cancellation, configure/clear during work, and storage failure. Compare direct digest probing and bounded inventory/index maintenance. Do not trade away correct eviction accounting or create unbounded blocking worker tasks merely to make the first call appear fast.

**UI and lifecycle remain trace-driven.** Field-level playback publication already exists. Capture actual SwiftUI update causes and hitch intervals for rapid scrubbing, sidebar activity and resizing before changing observation architecture or refresh frequency. Repeated close/reopen and mixed-source tests should distinguish continuing retained-owner growth from framework/allocator caches. No reason has emerged in this pass to reduce image budgets, remove normal animation, tear down every warm cache, or rewrite the renderer.

Acceptance should require correct output plus lower measured work in the relevant app scenario, no durable-data regressions, no new idle work, and characterized tail behavior. Linux component medians should not become hard macOS CI thresholds.

## 8. Delivery and application

The **cumulative patch** includes the first pass and this follow-up, against the pinned repository baseline. The **v2-only patch** applies after the exact first-pass patch. They are alternatives: do not apply both. The delivery contains selected changed/additional files, not a complete Illiquid checkout. Apply on a separate local branch and check for concurrent changes:

```sh
git status --short
git apply --check /path/to/illiquid-nondecoding-v2-cumulative.patch
git apply /path/to/illiquid-nondecoding-v2-cumulative.patch
```

Run the standalone drivers in `Benchmarks/NonDecodeFollowup/README.md`, then the real macOS core/native/app suites and release build. Existing historical evidence stays in its original directory; new receipts are in `Benchmarks/NonDecodeFollowup/evidence`. Source/binary hashes establish the exact measured implementations. The package validation receipt records patch application/reversal and packaged-source checks.

**Recommended integration order:** review deferred capture as one change, queued preview promotion/mailbox as a second, and diagnostics/tests as explicit supporting changes. Keep both candidates behind native qualification rather than declaring the entire player faster from component timing. The first change has real Foundation/store execution evidence here; the second has real concurrency/filesystem logic evidence but native image adapters.

## Source references

Repository links refer to the pinned baseline, not mutable `main`:

- [S1: history store](https://github.com/Jagalite/illiquid/blob/854f8365750a0e4f046ab7015e01ca7a138ada40/Sources/IlliquidCore/Persistence/PlaybackPersistenceStore.swift) and [coalescing writer](https://github.com/Jagalite/illiquid/blob/854f8365750a0e4f046ab7015e01ca7a138ada40/Sources/IlliquidCore/Persistence/CoalescingPersistenceWriter.swift).
- [S2: resident cache](https://github.com/Jagalite/illiquid/blob/854f8365750a0e4f046ab7015e01ca7a138ada40/Sources/IlliquidNativePlayback/Media/NativeThumbnailCache.swift) and [disk actor](https://github.com/Jagalite/illiquid/blob/854f8365750a0e4f046ab7015e01ca7a138ada40/Sources/IlliquidNativePlayback/Media/NativeThumbnailDiskCache.swift).
- [S3: controller checkpoint condition](https://github.com/Jagalite/illiquid/blob/854f8365750a0e4f046ab7015e01ca7a138ada40/Sources/IlliquidPlayer/Player/PlaybackController.swift#L2011-L2018) and [separate session-checkpoint writer](https://github.com/Jagalite/illiquid/blob/854f8365750a0e4f046ab7015e01ca7a138ada40/Sources/IlliquidPlayer/Player/PlaybackCheckpointWriter.swift).
- [A1: Swift SE-0306 actors, ordering and reentrancy](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0306-actors.md).
- [A2: Apple, Improving app responsiveness](https://developer.apple.com/documentation/xcode/improving-app-responsiveness).
- [A3: Apple, Reducing disk writes](https://developer.apple.com/documentation/xcode/reducing-disk-writes).

New numerical findings come from the bundled experiment receipts, not the external documentation. Raw receipts take precedence over rounded tables.
