# Illiquid: non-decoding performance research — fifth pass

**Date:** October 16, 2026.

**Pinned upstream:** `854f8365750a0e4f046ab7015e01ca7a138ada40`; checked through connected GitHub.

**Comparison:** v4 candidate versus v5. V4 did not change `PlaybackState.swift`, so its baseline for this particular file is the original upstream implementation.

**Status:** implemented selected-source candidate, actual-core/Observation tests completed; full macOS application qualification outstanding. No remote commit or PR.

## Executive assessment

This pass moves beyond thumbnail and persistence work into the synchronous **state-to-view publication path**. One production file changes: `Sources/IlliquidCore/Player/PlaybackState.swift`. Compound setters publish one completed snapshot, small no-op setters avoid redundant publication, and track catalogues use capacity-aware partitioning. There is no new cache, background task, timer, dropped position sample, reduced refresh rate, decoder change, or persistence policy change.

In the final order-balanced cohort, changing a chapter ID costs **4.958 → 3.212 µs**, replacing eight audio devices costs **6.623 → 3.534 µs**, replacing eight tracks costs **7.693 → 4.400 µs**, and appending a diagnostic at the history cap costs **8.710 → 4.728 µs**. These are whole method-to-view-store service times in the selected harness, not screen rendering or input-to-photon measurements.

Allocation experiments establish two concrete improvements: 5,000 diagnostic updates request **20,800,000 → 10,400,000 bytes**; 10,000 equal 128-track catalogue updates request **228,000,000 → 113,280,000 bytes**. Those are cumulative allocation-request bytes, **not resident RAM savings**. The ordinary position loop already makes zero observed malloc-family requests after warmup in both variants.

The most important research qualification is that review found an **ordering bug in the initial benchmark runner**. Rotation plus odd-round reversal canceled each other for two variants, leaving the baseline first. The runner is corrected, and all headline values below come from **288 new order-balanced timing observations and 81 separately metered observations**. Earlier observations remain labeled exploratory. A checker verifies the actual emitted order and rejects the old sequence.

**Recommendation:** qualify the focused state change independently of the larger cumulative cache/persistence candidate. It removes real redundant work and temporary publication states. It does not establish a general UI/FPS, energy, or physical-footprint improvement. Ordinary position publication remains a few microseconds in this fixture, so the result does not justify a wholesale observation-framework rewrite.

## 1. Experiments and decisions

| ID | Question / trial | Evidence and disposition |
| --- | --- | --- |
| E25 | Do compound setters trigger repeated complete snapshots? | Actual coordinator wiring and baseline diagnosis show two callbacks for chapters, devices, track partitions, and a capped diagnostic. **Batch synchronously at the existing method boundary.** |
| E26 | Does an equal assignment still run Illiquid's callback? | The supplied compiler expansion plus an actual Observation probe shows `didSet` still running; baseline equal volume causes one app callback. **Guard small unchanged values.** |
| E27 | Does intermediate diagnostic publication cause extra copying? | Connected callback: two allocations per message versus one. Disconnected control: zero in both. **Keep one capped final publication.** |
| E28 | Should every array get another equality precheck? | Initial 10k-chapter trial slowed approximately 25%. **Rejected.** Remove the extra array scans; retain compound batching. This initial timing was order-confounded and is exploratory evidence, not a universal overhead estimate. |
| E29 | Can partition allocation be reduced without another cache? | Count audio entries, reserve the required count for each output, then partition in input order. Final allocator cohort falls from 14 to two allocations per 128-track refresh. **Implemented.** |
| E30 | Are output, authority ownership, observation isolation, and lifetime retained? | 15 shared regression scenarios; 20k mixed operations with 60k comparisons; release/debug pass. **Component-qualified.** |
| Q01 | Is paired process ordering actually balanced? | Initial two-variant driver was wrong. **Corrected and rerun; old datasets excluded from headlines.** Recorded-order checker passes and rejects old evidence. |
| C04 | Do genuinely changed scalar/position controls improve? | Small mixed results, including slightly higher changed-volume/adjustment medians. **No general steady-playback speedup claim.** |

These experiments do not add a Swift database provider, incremental thumbnail inventory, native rendering rewrite, or lower image budgets. The four earlier reports retain their own results and outstanding release gates.

## 2. Cause: callback fan-out before an already selective view store

The coordinator connects `PlaybackState.onMutation` to `viewStore.publish(PlaybackViewSnapshot(state: playbackState))` [S2]. Each callback therefore constructs the complete immutable projection and enters the view store. The view store already checks equality and publishes only changed fields [S3]. Ordinary authority/position projections already use state batching and field guards; an existing upstream test explicitly checks this [S4]. Those optimizations are not new work in v5.

Some metadata/control methods, however, updated several properties without using the existing batch mechanism. For example, `updateChapters` assigned the array and then the current ID; `recordDiagnostic` appended and then removed the excess after crossing 100. Each property observer could independently invoke the coordinator callback [S1]. The baseline diagnosis observes a chapter snapshot with the new array and old ID, and a transient published diagnostic array of 101 entries. That does **not** prove a person saw those intermediate states on screen.

The final implementation extends `performMutationBatch` to chapters, audio-device list/selection, track partitions, shell-error/recovery context, filter insertion/sorting, and capped diagnostics. Publication remains synchronous before the method returns. Independent logical updates remain independently published; no task scheduling, debounce interval, periodic timer, or cross-event conflation is introduced.

This guarantees a complete value at this **app callback boundary**, not a universal atomic transaction for every Observation property. Direct observers of individual `PlaybackState` or `PlaybackViewStore` properties still have their own notification semantics, and `PlaybackViewStore.publish` still assigns fields individually. SwiftUI may already coalesce some synchronous changes. Fewer app callbacks must not be equated with an equal reduction in SwiftUI body evaluations or render passes. Apple's profiling guidance distinguishes data-driven updates, view-body computation, layout, and rendering/hitches [A1, A2].

### Small no-op guards and retained behavior

Scalar/small-value setters now compare before assignment. Video adjustments are changed in a local value and assigned only when different, following the existing video-output update pattern. The mutation closure still runs once. Array catalogue setters deliberately do **not** add another full-array precomparison; an equal catalogue can still produce one callback, rather than the previous two.

Equal shell-error text is not sufficient to skip all work: a dismissed or different recovery issue must still be restored to the requested message. Clearing the shell error does not silently clear persistent recovery context. Track catalogue updates do not take over authority-owned selection; a subsequent core projection still refreshes the selected track metadata. Repeated diagnostic messages remain repeated; this is not log deduplication.

No new input-sanitization policy is introduced for volume or speed. Existing invalid projection, ratio, and delay behavior is retained and tested. Differential equivalence uses the declared value equality, not JSON/bitwise floating-point identity or an identical notification trace. Consumers must not treat `onMutation` as acknowledgement of every setter invocation; its documentation now explicitly describes projection notification and possible no-op silence.

## 3. Measurement protocol and scope

**Environment:** Linux x86-64, AMD EPYC 9V74, glibc 2.41, Swift 6.2.1. This differs from the Intel host of v4; compare paired v4/v5 runs from this pass, not absolute numbers across reports. The shared host was not otherwise quiesced, clock-frequency controlled, or thermally isolated.

The benchmark builds actual selected production value types, `PlaybackState`, and `PlaybackViewStore` into a separate `IlliquidCore` static library, with a separately compiled client. Both use `-O -whole-module-optimization -swift-version 6 -warnings-as-errors`. Actual Foundation and Observation are used—**no image, Observation, or UI-state mocks**. Only the exact supporting `PlaybackRepeatMode` and `VideoScaleMode` declarations are excerpted from unrelated files to avoid requiring geometry/playlist modules.

The supplied Linux dynamic Observation library had an unresolved hidden Swift threading symbol. `-static-stdlib` links the matching supplied Swift implementation and resolves that environment problem without substituting functions. The same linkage is applied to all variants. On macOS the driver does not force static Swift-runtime linkage. This is still not an SDK/application build or the project's pinned native toolchain qualification.

Each observation is a fresh process. Fixture creation, module/framework startup, and **200 warmup calls** precede timing. Loops contain 400–20,000 synchronous calls, depending on workload; the client reads and verifies the final state, checks callback counts, and consumes the result. The position fixture has selected tracks near the front of the catalogues. It is not exhaustive coverage of every selection/catalogue size.

Primary two-variant runs use baseline/candidate then candidate/baseline on alternating repetitions: nine repetitions per workload. Three-variant allocation runs rotate positions, with three repetitions per workload. The final checker verifies complete unique identities, order, and the recorded `process_order`. No completed outliers are removed. Both wall time and process CPU time are retained; allocator instrumentation is in separate runs and its timings are not mixed into the primary tables.

Reported microseconds are **medians of each process's mean per-call time**, not p95/p99 interaction latency. There is no real user-input delivery, AppKit run loop, live SwiftUI subscriber graph, layout, frame presentation, decode, or I/O in the timed state loop. A faster state handoff can reduce work, but visible responsiveness still needs a native trace.

## 4. Final paired service-time results

Nine fresh-process observations per variant and row. Full min/max, process CPU, callback counts, source hashes, and individual observations are in `evidence/final-timing`.

| Operation | v4, µs/call | v5, µs/call | Change |
| --- | ---: | ---: | ---: |
| Current chapter changes; same 128-chapter catalogue | 4.958 | 3.212 | -35.2% |
| Replace 128 chapters; change at the final entry | 5.603 | 3.837 | -31.5% |
| Replace eight audio devices/selection | 6.623 | 3.534 | -46.6% |
| Repeat equal eight-track catalogue | 6.214 | 3.700 | -40.5% |
| Replace eight-track catalogue | 7.693 | 4.400 | -42.8% |
| Repeat equal 128-track catalogue | 44.759 | 29.982 | -33.0% |
| Replace 128-track catalogue | 23.938 | 14.828 | -38.1% |
| Append a diagnostic at the 100-message cap | 8.710 | 4.728 | -45.7% |
| Repeat identical chapters and ID | 3.528 | 1.593 | -54.8% |
| Set the existing volume | 1.533 | 0.019 | -98.8% |
| Apply a no-op video adjustment | 1.677 | 0.084 | -95.0% |

A chapter-ID update, device change, track-catalogue update, or capped diagnostic now enters the snapshot publisher once rather than twice in these cases. The final 20,000-operation mixed corpus produces **23,040 baseline callbacks versus 15,300 candidate callbacks**, a 33.6% reduction for that synthetic mix. It preserves the final value after every operation and both view stores' correspondence to their states. This corpus is not a claim about the real application's event distribution.

### Negative and ordinary-work controls

| Operation | v4, µs/call | v5, µs/call | Change |
| --- | ---: | ---: | ---: |
| Ordinary changing position, selected tracks near the front | 3.417 | 3.323 | -2.7% |
| Genuinely changing volume | 2.831 | 2.845 | +0.5% |
| Genuinely changing video adjustment | 3.213 | 3.291 | +2.4% |
| Replace 10,000 chapters; change at the final entry | 63.233 | 60.615 | -4.1% |
| Diagnostic append with the publication callback disconnected | 0.299 | 0.263 | -11.9% |

Changed volume and changed adjustments have slightly higher medians: about 0.5% and 2.4%, respectively, in the final balanced cohort. Ordinary position is slightly lower in median but has a worse maximum observation; the body was already guarded and batched upstream. Do not advertise a general steady-playback or tail-latency improvement.

The 10k-chapter control is approximately 4.1% lower in median in the balanced final cohort, with overlapping/wide ranges (**60.974–78.714 µs** before; **54.350–81.350 µs** after). Earlier order-confounded cohorts showed higher candidate medians, including approximately 25% for the rejected blanket-guard trial and 2.7–6.6% after narrowing it. The corrected experiment does not establish a robust large-catalogue speedup or erase those observations. The worthwhile design lesson is to avoid adding a full-array scan without measuring both equal and genuinely changed values.

No time-based thresholds or catalogue-size heuristics were introduced to special-case a favorable benchmark size. A no-op scalar is much cheaper, but its savings are only around 1–2 microseconds per call here, and its frequency in real playback remains unmeasured.

## 5. Track partitioning: fewer allocations without persistent metadata

Two `filter` calls traversed the input twice and grew two output arrays. The new code also makes two passes: count audio tracks; reserve each partition's required element count; then append audio/subtitle entries in original order. It avoids reserving `tracks.count` for both outputs, which would request unnecessary capacity. Actual allocation rounding remains the Swift allocator's responsibility.

It neither caches the incoming catalogue nor introduces invalidation/revision bookkeeping. Empty, single-kind, mixed, and duplicate-ID catalogues retain their partition order and metadata. Same ID with changed title remains a real change. The enum switch remains exhaustive.

An initial partition ablation held batching constant and observed lower 128-track refresh times, but those timings used the flawed two-variant order and are exploratory only. The balanced three-variant allocator cohort provides the clearer attribution: the **batched** intermediate has the same track allocation totals as v4, while the final capacity-aware implementation reduces them. Thus batching does not get credited for partition allocation savings.

## 6. Allocation results and memory interpretation

Three metered observations per variant/workload, using the existing Linux/glibc interposer. Fixture creation, warmup, and result serialization are outside the measured loop. Counters measure successful malloc/calloc/realloc request counts and cumulative requested sizes; they do not subtract frees, capture every allocation/VM mechanism, or measure live/peak heap, RSS, compressed memory, GPU memory, or macOS physical footprint.

| Timed loop | Requests, v4 → v5 | Requested bytes, v4 → v5 |
| --- | ---: | ---: |
| 5,000 diagnostics with connected publication | 10,000 → 5,000 | 20,800,000 → 10,400,000 |
| 5,000 diagnostics, callback disconnected | 0 → 0 | 0 → 0 |
| 10,000 equal eight-track refreshes | 60,000 → 20,000 | 14,240,000 → 7,680,000 |
| 10,000 equal 128-track refreshes | 140,000 → 20,000 | 228,000,000 → 113,280,000 |
| 5,000 changed 128-track refreshes | 70,000 → 10,000 | 114,000,000 → 56,640,000 |
| 20,000 position changes | 0 → 0 | 0 → 0 |
| 10,000 chapter-ID changes | 0 → 0 | 0 → 0 |
| 20,000 equal volume setters | 0 → 0 | 0 → 0 |

Diagnostics halve their measured buffer-copy allocation traffic. The disconnected control supports the mechanism: publishing the intermediate appended array creates another shared value before trimming, while batching allows trimming before that publication. Immutable previously published snapshots remain immutable; one necessary copy can remain when a value is still shared.

Track partitioning reduces requested bytes by **46.1% at eight tracks** and **50.3% at 128 tracks**, in these balanced mixed-kind fixtures. There is no extra retained catalogue cache. Ordinary position and chapter-ID paths were already allocation-free within this meter's warm loop, so their CPU changes must not be presented as an allocation reduction.

**The 114.72 MB reduction across 10,000 track refreshes is not 114.72 MB less resident player RAM.** It is repeated transient traffic. Neither catalogue refreshes nor diagnostics should be assumed to occur at video frame rate. Real event counts and allocation generations are needed to translate the component results into application impact.

## 7. Correctness and validation

**Executed with the actual core/Observation runtime:** 15 shared scenarios and **987 assertions** in release and debug. They cover compound snapshot coherence; no-op versus changed setters; 400 capped diagnostic appends, order, empty messages and duplicates; filter ordering; shell-error/recovery behavior; no-op adjustment observation; position isolation; invalid values; reentrant callbacks; immutable prior snapshots; metadata lifecycle; weak connection lifetime; and 32 partition cases spanning zero to 1,000 tracks.

**Executed differential check:** 20,000 deterministic mixed operations through both the original and final state implementation, with **60,000 comparisons**, in both configurations. The original class is renamed only so both implementations coexist; supporting values and view-store logic are actual source. All final snapshots match by declared equality, and each view store matches its current state. Intermediate callback traces are intentionally different.

**Baseline diagnosis:** chapters produce two callbacks with a mixed intermediate snapshot; the capped diagnostic produces two callbacks and a maximum published count of 101; equal volume produces one app callback; no-op adjustment produces one source-Observation notification. The candidate reports one coherent chapter callback, one capped diagnostic callback/max 100, and zero for the two no-op cases. The baseline view store's equality checks already suppress some downstream no-op notifications. This is not proof of reduced visible redraws.

The 15 XCTest wrappers typecheck on Linux against the actual module. The standalone runner executes their exact shared scenario bodies, but XCTest discovery/runtime execution itself is **not** claimed. The existing upstream `PlaybackStateTests` was reviewed; its authority batching and stable-view-field expectations remain represented in this pass's checks, but that upstream test file was not executed here [S4].

The compile-time signpost branch also typechecks with the Linux/no-`os` branch of the existing helper. The Darwin signposter and macOS application remain unqualified. Earlier cache/persistence source and receipts are carried forward unchanged; their suites were not rerun during this new state-only pass.

### Research-runner correction and provenance

There are **1,537 completed current-pass observations** in the archive: 1,168 exploratory observations before the sequencing fix, plus the 369 final balanced timing/allocation observations. The number is not a claim of independent end-to-end tests. Only the final balanced cohorts supply the headline comparison.

`baseline/RunnerBeforeOrderFix.py` preserves the faulty driver. `validate-orders.py` rejects its actual final-unbalanced dataset and passes both final cohorts; its self-checks also reject duplicated observations. Production, harness, and final test-file hashes match the final measured manifests. Earlier variant labels are mapped in `evidence/execution-notes.json` rather than silently relabeled: an early `v5` means the guarded or batched intermediate, not the shipped final source.

The first exploratory guarded cohort references an older assertion-only test-helper version whose exact original bytes were not retained. Its production and timed benchmark harness sources are retained; those assertion edits were outside the timed loop. This limits byte-for-byte reconstruction of that preliminary binary, not final-candidate reproduction. The later batched test-helper version is archived, and the final cohorts match delivered sources. No claim is made that every historical driver version or binary can be reproduced identically.

**Not performed:** the full repository/app graph, macOS SDK build, pinned native test runtime, release/signature or architecture checks, real Instruments/SwiftUI/AppKit tracing, live hover/scrub/resize/PiP/sleep/wake, physical footprint or energy, actual media workloads, or performance on the user's Mac. This remains a candidate pending those gates.

## 8. Instrumentation and next work

`PlaybackStatePublish` brackets the synchronous `onMutation` callback, including snapshot construction and view-store publication in the real coordinator wiring. It excludes any wait before entering the main actor and does not measure eventual layout/rendering. The probes are compiled only when `ILLIQUID_STATE_SIGNPOSTS` is defined; the existing helper additionally requires bundle ID `com.example.IlliquidBenchmark`, `ILLIQUID_ENABLE_BENCHMARK_OVERRIDES=1`, and `ILLIQUID_BENCHMARK_NONDECODE=1`.

Ordinary builds have no newly inserted publication probe. Enabled diagnostics record no media path and introduce no sample arrays or timers. Run primary resource comparisons without the define; profile separate diagnostic builds with it enabled. Native signpost visibility/API compilation still needs checking.

The next useful Mac experiment is to correlate these publication intervals and actual event counts with SwiftUI view causes, layout/commit work, frame hitches, and allocation generations [A1, A2]. Include real seeks, volume changes, sidebar/track menus, device changes, subtitle toggles, and diagnostic bursts. Test ordinary position updates with no selected subtitle, selections late in larger catalogues, and source transitions—not only this fixture's early selected IDs. Validate coherent snapshots without assuming per-property notification atomicity.

For larger absolute improvements, the earlier full-history serialization and disk inventory targets remain important. This pass neither implements nor rejects a Swift transactional-history provider or incremental inventory. The evidence instead argues against spending the next effort on a blanket rewrite of a basic position-publication path that is already inexpensive in the measured fixture. Choose the next UI change from a real cause trace, not from callback counts alone.

## 9. Reproduce and integrate

The **cumulative patch** includes all five passes against the pinned selected upstream files. The **v5-only patch** applies after the exact v4 candidate. **Use one, not both.** The archive is a selected-source tree; do not replace a complete checkout with its `candidate/` directory.

```sh
git status --short
git apply --check /path/to/illiquid-nondecoding-v5-cumulative.patch
git apply /path/to/illiquid-nondecoding-v5-cumulative.patch

python3 Benchmarks/NonDecodeFifthPass/run.py \
  --tests-only --output /tmp/illiquid-state-tests
python3 Benchmarks/NonDecodeFifthPass/run.py \
  --variants v4 v5 --repeats 9 --output /tmp/illiquid-state-timing
python3 Benchmarks/NonDecodeFifthPass/validate-orders.py /tmp/illiquid-state-timing
```

`Benchmarks/NonDecodeFifthPass/README.md` documents the debug, allocator, ablation, and full macOS follow-up commands. Output directories must be new or empty. Source manifests, raw observations, min/max summaries, process order, command logs, and test receipts are retained. Package application/reversal/hash validation is distinct from native app qualification.

## References

[S1] Pinned [`PlaybackState.swift`](https://github.com/Jagalite/illiquid/blob/854f8365750a0e4f046ab7015e01ca7a138ada40/Sources/IlliquidCore/Player/PlaybackState.swift), original Git blob `0f9014ba2a41029a20410ddf51c0271fe341224a`.

[S2] Pinned [`PlaybackController.swift`](https://github.com/Jagalite/illiquid/blob/854f8365750a0e4f046ab7015e01ca7a138ada40/Sources/IlliquidPlayer/Player/PlaybackController.swift), coordinator initialization and `onMutation` connection.

[S3] Pinned [`PlaybackViewStore.swift`](https://github.com/Jagalite/illiquid/blob/854f8365750a0e4f046ab7015e01ca7a138ada40/Sources/IlliquidCore/Player/PlaybackViewStore.swift), original Git blob `c8511ca7c60ede45b1bc0557f6e768851cc80e25`.

[S4] Pinned [`PlaybackStateTests.swift`](https://github.com/Jagalite/illiquid/blob/854f8365750a0e4f046ab7015e01ca7a138ada40/Tests/IlliquidCoreTests/PlaybackStateTests.swift), original Git blob `a07cac12d529fdebd3e98f0675bcf25670697dfe`.

[A1] Apple, [Understanding and improving SwiftUI performance](https://developer.apple.com/documentation/Xcode/understanding-and-improving-swiftui-performance).

[A2] Apple WWDC25, [Optimize SwiftUI performance with Instruments](https://developer.apple.com/videos/play/wwdc2025/306/).

Numerical claims derive from the attached experiment receipts, not the external documentation. The corrected balanced cohorts are authoritative for this pass's final comparison.
