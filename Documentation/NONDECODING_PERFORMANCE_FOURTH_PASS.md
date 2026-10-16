# Illiquid: non-decoding performance research — fourth pass

**Date:** October 16, 2026.
**Pinned upstream:** `854f8365750a0e4f046ab7015e01ca7a138ada40`, checked through connected GitHub.
**Experimental baseline:** the previously delivered **v3 candidate**, not unmodified upstream.
**Status:** implemented selected-source candidate; native macOS qualification outstanding. No remote commit or PR.

## Executive result

This pass fixes the duplicate thumbnail-file accounting defect left open in v3 and removes full-directory inventory from the successful first foreground disk-lookup path. The cache now records **physical filenames separately from logical digest identity**, deterministically prefers a foreground alias, and can fall back to a valid background copy if the foreground image is corrupt. Both aliases count toward quotas and explicit clearing.

In the selected Swift/Linux cache harness, a first foreground disk hit among 8,191 files fell from **559.211 to 2.104 ms**. A first background-file hit needing promotion fell from **628.697 to 2.850 ms**. These are real filesystem/cache-control-flow measurements with explicitly synthetic image codecs, not a macOS preview or whole-player speedup.

The optimization is **scheduling/dependency removal, not faster full inventory**. Requesting usage immediately afterward still forces the scan. In the first-hit case, read-plus-usage was **559.291 → 638.620 ms**. The standalone full-inventory control was about **6.4% slower** in this small cohort. The empty-directory miss also regressed **0.916 → 3.256 ms**, partly because the new path initializes hashing/JSON that the old empty-index path avoids. These results are retained, not filtered out.

There are **141 new timing observations and 12 separately metered allocation observations**. The candidate passes 6,165 assertions across 20 scenario executions in both optimized and debug builds; existing inventory, mailbox, preview-adapter and persistence suites were rerun. Eight native tests are authored and syntax-parsed only.

**Recommendation:** review the accounting correction independently, then qualify exact first-access lookup on a Mac with populated and empty caches. Do not claim lower total CPU/energy/RAM or a universal speedup. The per-record Swift persistence provider remains a separate, unimplemented next project; no further SQLite integration is claimed here.

## 1. Experiment and decision register

| ID | Question / trial | Outcome | Disposition |
| --- | --- | --- | --- |
| E20 | Can both b-/f- aliases be accounted and cleared without losing foreground semantics? | Baseline accounts one copy and leaves an orphan; candidate counts both, prefers foreground, clears both | Implemented correctness fix |
| E21 | Can foreground disk access avoid complete inventory? | Constant-number exact probes return before inventory; first-hit and miss matrix improves with populated directories | Implemented candidate with explicit maintenance tradeoff |
| E22 | Can corruption, failed removal and promotion coexist with separate physical accounting? | Corrupt preferred copy falls back; failed unlink stays accounted; directory/symlink fixtures survive | Component tests pass; native frameworks unqualified |
| E23 | Is partial indexing bounded and are write quotas preserved? | Temporary index is cleared after synchronous lookup; full inventory precedes writes/usage/background reads; 8,194-copy quota fixture passes | Implemented; no unbounded partial index |
| E24 | Are allocations reduced globally or moved? | First foreground interval avoids 171 MB of cumulative allocation requests, but later inventory still executes | Foreground-path allocation deferral only; not total/RSS savings |
| C03 | Empty cache, full inventory, warm reads and at-capacity insert controls | Mixed, including slower empty misses, full inventory and churn medians | No universal speedup; mandatory Mac controls |
| A01 | Physical accounting alone, keeping inventory-first lookup | Intermediate ablation still pays directory-sized first-access work | Retained fixture separates correctness from latency policy |
| D06 | Implement a production SQLite provider in this pass | Not attempted; no new storage-provider or migration tests | Remains next architectural project |

No decoder, renderer, pixel conversion, subtitle/audio output, cache size preference, refresh cadence, or history checkpoint cadence changed. Unlike an assertion of identical timing behavior, the **point at which preexisting on-disk overage is pruned does change**; section 3 documents this explicitly.

## 2. Duplicate physical entries: reproduce, fix, and boundaries

### Original defect

V3 indexed `files[digest]`. Creating `b-<digest>.jpg` of 128 bytes and `f-<digest>.jpg` of 256 bytes yields two recognized regular files but only one dictionary entry. In this run the old actor reported **256 of 384 logical bytes**, returned clear success, and left one file. The previous pass observed the opposite enumeration winner; neither order is a contract. See `release-tests/tests.json` for the diagnostic, which is not counted as a passed test.

### Implemented behavior

The index key is now the full cache basename. `f-<digest>.jpg` and `b-<digest>.jpg` therefore occupy separate entries and contribute their own file lengths. Lookup tries foreground first, then background. A failed decode removes only that physical entry; it does not delete the other alias or forget its bytes. Valid backups are not eagerly deleted just because a foreground file exists.

Promotion changes a basename only if the move succeeds, reconciles a formerly indexed destination that disappeared, and marks a foreground-used entry as protected in memory even if its physical rename fails. In the pre-inventory exact path, such a rename failure falls back to full inventory so this protection is not lost when the temporary index is discarded. That error fallback may be slow by design.

Eviction still prefers background entries and older use dates. Equal-date ties are now deterministic by filename, rather than relying on dictionary iteration order. Reservation checks continue using the **logical digest**, so changing the physical index key does not accidentally bypass the mailbox. The existing per-process epoch and in-flight encode fences remain.

The count ceiling is unchanged numerically (8,192); duplicate aliases now each consume an entry. Initial inventory retains the prior trim-to-8,191 behavior when at/over that ceiling. The quota test starts with 4,097 digest pairs (8,194 physical entries), removes three background copies, preserves every foreground copy, and clears all remaining recognized files.

### Deletion and error semantics

Nonrecursive `unlink` remains. A known file replaced by a directory fails deletion, its prior bytes remain conservatively accounted, and clear reports failure while still removing other known aliases. Static directories and symlinks encountered during inventory/direct probing are ignored. POSIX specifies final-symlink removal rather than recursive traversal for unlink [R2]. These tests do not claim protection against every parent-directory replacement or concurrent hostile filesystem race.

Counters sum **logical file lengths**, not allocated APFS blocks, sparse-file allocation, compression savings, or hard-link deduplication. Correctness here means both known directory entries are represented. This remains a single-process cache index, not an externally synchronized directory monitor. Files changed/created by another process after complete inventory are not continuously re-inventoried, and preexisting best-effort enumeration/error handling is not redesigned. Clear is scoped to recognized/indexed files, not arbitrary contents of the directory.

## 3. Exact first-access lookup before inventory

### Execution path

For a foreground request before full inventory, derive the existing digest and probe only its `f-` and `b-` filenames. Validate regular-file/nonsymlink metadata, use the existing image read semantics, promote if needed, and return. There is no directory traversal on the successful ordinary path, no persistent negative cache, and no cache-key/renderer-version change.

The actor stores at most those two temporary entries during that synchronous operation and discards them on return unless an error fallback has completed inventory. There is no await within that temporary scope. A sequence of 100 alternating foreground hits and misses verifies zero retained partial-index entries/bytes after each call. This prevents a long foreground-only session from building an unbounded partial metadata index.

Awaited and mailbox-queued promotions use the same exact probing before inventory. The mailbox still has its existing 128-distinct-digest limit, one drainer, reservation/eviction ordering, epoch reset, and fallback. In-flight writes can only exist after inventory, so their promotion flags continue to use the complete-index path.

### Required full-inventory boundaries

Background reads, new disk insertion, explicit usage, explicit clear, and applicable reconfiguration still use complete inventory before their accounting-dependent action. No newly encoded payload is admitted using a partial index. The test with an existing over-budget directory verifies that a direct foreground read can return, but the next insertion inventories/trims before admitting additional bytes.

This deliberately defers pruning of a **preexisting** over-budget cache during foreground-only reading. A valid old image may be served before unrelated excess files are removed. There is no automatic new timer or background inventory task. Existing preparation/maintenance/usage can subsequently trigger the scan. A foreground-only session may therefore leave preexisting overage until such an action; the change is not an always-enforced-at-first-read disk-budget policy. Existing resident-image budgets are unchanged.

The exact path is not free and not universally nonblocking. File metadata, read/decode and rename still execute on the disk actor. It cannot jump ahead of filesystem work already occupying that actor, and a blocked OS call is not made cancellable by avoiding inventory. A failed physical promotion intentionally falls back to inventory. Separate bounded I/O execution/incremental scanning would be another architectural change, not something this patch silently provides.

## 4. Measurement protocol and results

Linux x86-64, Intel Xeon Platinum 8573C, Swift 6.2.1. `swiftc -O -swift-version 6 -warnings-as-errors`; the debug build is used only for correctness. The shared host was not quiesced, no OS cache purge occurred, and fixture creation precedes timing. Each observation is a fresh process. Variant order alternates within rounds. Compiler, binaries, source hashes and mount details are recorded in `evidence`.

The image adapter stores a short header and padding, **not a JPEG**. Real Foundation directory enumeration, stat/resource lookups, file reads, renames, unlinks, atomic writes, actor logic, digests and mailbox logic execute. The runner substitutes the image codec helper, not `image(for:)`; the candidate's exact lookup/fallback flow is actually exercised. Native ImageIO decoding remains unmeasured. Its eager-decoding option is preserved in production [R3].

First-hit cases add one target to the specified number of unrelated files. The first-access interval starts before the actor call, so it includes queue/handoff and one-time framework costs in that process. Fixture construction, subsequent usage, and the final physical reconciliation helper are outside that interval. All benchmark rows verify final accounted bytes against actual regular-file lengths after usage. Repeated disk reads are not resident-RAM hits.

### First-access time

| Workload | v3 median | v4 median | Samples per variant |
| --- | ---: | ---: | ---: |
| First foreground-file hit; 1 total file | 1.542 ms | 1.783 ms | 5 |
| First foreground-file hit; 1,001 files | 89.064 ms | 5.334 ms | 5 |
| First foreground-file hit; 8,191 files | 559.211 ms | 2.104 ms | 5 |
| First background-file hit and promotion; 8,191 files | 628.697 ms | 2.850 ms | 5 |
| Miss; empty directory | 0.916 ms | 3.256 ms | 5 |
| Miss; 1,000 unrelated files | 79.831 ms | 1.159 ms | 5 |
| Miss; 8,190 unrelated files | 611.853 ms | 1.699 ms | 5 |

The intermediate accounting-only variant still took 577.906 ms for the 8,191-file foreground hit and 741.709 ms for the background-file hit. Its purpose is an ablation: correcting physical accounting alone does not remove directory-size-dependent startup lookup. Those absolute medians vary on the shared host and do not establish a universal accounting-overhead percentage.

### Controls and repeated requests

| Workload | v3 median | v4 median | Samples per variant |
| --- | ---: | ---: | ---: |
| Complete inventory; 8,191 files | 566.722 ms | 602.730 ms | 3 |
| Background lookup, inventory-first; 8,191 files | 634.327 ms | 573.838 ms | 3 |
| 100 pre-inventoried disk reads | 12.284 ms | 10.268 ms | 3 |
| 32 inserts at disk count capacity | 50.434 ms | 51.329 ms | 3 |
| 32 distinct foreground lookups before inventory | 581.831 ms | 14.435 ms | 3 |

These controls are deliberately mixed. The complete inventory median is higher in v4, while a background read that includes inventory is lower. Warm disk reads are lower in this cohort, and at-capacity insert churn is about 1.8% higher. Three samples do not support a general hot-path or CPU ranking. The new algorithmic property is the first foreground dependency reduction, not uniformly cheaper disk work.

### Include the deferred scan

| Workload | v3 median | v4 median | Samples per variant |
| --- | ---: | ---: | ---: |
| First foreground-file hit + usage; 8,191 files | 559.291 ms | 638.620 ms | 5 |
| First background-file hit + usage; 8,191 files | 628.761 ms | 811.059 ms | 5 |
| 32 foreground lookups + usage; 8,191 files | 581.871 ms | 572.982 ms | 3 |

The scanner has not vanished. Read-plus-usage is higher in both single-hit large-cache cases; the 32-request sequence is roughly unchanged once usage forces inventory. `read_plus_usage_ns` is the sum of the timed read loop and immediately following usage call, excluding the benchmark-only stats/reconciliation helpers. It is not a visible frame or application lifecycle interval.

Only completed rows are included, no completed outliers were removed, and every min/max remains in `summary.json`. Several orchestration windows were interrupted; the resumable driver retained finished identities and verified unchanged manifests before continuing. `execution-notes.txt` records those interruptions. The final set has 141 unique timing rows, not a p95/p99 UI latency distribution.

## 5. Allocation traffic: removed from the foreground interval, not from future maintenance

Separate Linux/glibc interposition measures successful malloc/calloc/realloc request counts and cumulative requested sizes. It stops **before** the following usage/inventory operation. It does not subtract frees, include every allocator/VM mapping, or measure live/peak heap, RSS, compressed memory, GPU memory or macOS physical footprint.

| Measured interval | v3 requested bytes | v4 requested bytes | v3 → v4 request count |
| --- | ---: | ---: | ---: |
| First foreground hit; 8,191 files | 171,450,906 | 54,256 | 515,553 → 254 |
| Miss; empty directory | 118,177 | 276,335 | 58 → 4,597 |

Values are medians of three processes. The large-cache foreground interval avoids about 99.97% of that allocation traffic, and no partial index remains afterward. **It does not demonstrate 171 MB less live application memory**, nor eliminate the inventory allocation when maintenance eventually runs. The empty-miss result is worse: without fixture hashing beforehand, the exact path pays first-use digest/JSON work skipped by the old empty-index path. The negative control prevents generalizing populated-cache savings to every first preview.

## 6. Correctness, regression and build evidence

**New selected-code suite:** 6,165 assertions, 20 scenario executions, passed in release and debug. Counts include both alias creation orders, direct/indexed reads, corrupt preferred fallback, quota enforcement, failed deletion, directory and symlink fixtures, disappeared files, digest reservations, clear during encoding, 600 deterministic mixed operations with per-operation physical reconciliation, and bounded foreground-only lookup. These assertions are not thousands of independent end-to-end application tests.

**Intermediate accounting fixture:** 5,951 assertions in 16 overlapping scenario executions. V3's duplicate diagnostic intentionally records the existing incorrect behavior and is not counted as passing correctness.

**Existing suites rerun:** 2,319 inventory assertions; 196 candidate preview-adapter checks; five mailbox XCTest cases (including the existing 5,000 reserve/evict races); and 26 actual-core persistence XCTest cases in release. The native disk cache, resident cache and mailbox are integrated in the portable preview checks, but image frameworks remain explicit adapters. Unchanged first-pass ranking tests are not claimed as a new rerun in this pass.

**Authored and syntax-parsed only:** eight `ThumbnailPhysicalEntryTests` cases using actual CoreGraphics/ImageIO JPEGs. These have not been SDK-typechecked or executed on macOS. The changed production disk source also passes syntax parsing. The Linux adapter compilation does not qualify Darwin/ImageIO APIs.

**Not performed:** complete repository/app build, full test graph, release/signature or architecture checks, native macOS Instruments, real hover/scrub/resize/PiP/sleep/wake, energy/GPU/physical-footprint measurements, true cold OS-cache tests, power-loss/storage durability qualification, or a production SQLite provider. No workflow, dependency or remote repository content was changed.

## 7. Instrumentation and integration recommendation

The new `ThumbnailExactDiskProbe` signpost scopes exact metadata probing, alongside the existing disk-read, inventory and promotion intervals. It records no media path. Existing isolated-bundle identity and explicit benchmark flags remain required; no per-frame timer, unbounded event log or new background inventory task is introduced. Disabled branch/function overhead is not literally zero.

Review physical-file accounting/fallback as a correctness change first. Then qualify the direct startup path with first hit, miss, empty directory, repeated different keys, complete inventory and already-busy disk actor controls. Capture image-ready separately from visible pixels, plus CPU and total allocation/footprint with diagnostics off in the primary comparison. Exact lookup trades a populated-directory startup wait for a small empty-cache penalty and deferred housekeeping; acceptance should explicitly include that policy.

The next disk-side research should evaluate a bounded incremental inventory or dedicated bounded I/O executor, keeping one authoritative accounting state and explicit admission/clear/error rules. Merely making another detached task does not make blocking filesystem operations harmless or preserve ordering automatically. The existing incomplete-inventory/error behavior and out-of-process directory changes remain limits, not cleared risks.

The larger persistence direction from v3 still warrants a Swift transactional per-record provider with the complete history/settings/version/migration contract. This pass intentionally finishes a cache correctness/performance dependency instead of presenting another progress-only database prototype as a completed integration.

## 8. Reproduction and delivery

The cumulative patch contains all four passes against the pinned upstream selected files. The v4-only patch applies after the exact delivered v3 candidate. **They are alternatives; do not apply both.** Use a separate branch and `git apply --check` first. Do not replace a full checkout with the selected `candidate/` directory.

```sh
git apply --check /path/to/illiquid-nondecoding-v4-cumulative.patch
git apply /path/to/illiquid-nondecoding-v4-cumulative.patch
```

`Benchmarks/NonDecodeFourthPass/README.md` documents the paired variants, runners, adapters, allocation scope and native gates. `evidence/timing`, `allocations`, test receipts, source manifests and `timed-sources` identify exactly what ran. Packaged validation separately checks application/reversal and candidate hashes; it is not app-build qualification.

## References

[R1] Repository source and v3 baseline: `Sources/IlliquidNativePlayback/Media/NativeThumbnailDiskCache.swift`, `NativeThumbnailCache.swift`, and `ThumbnailPromotionMailbox.swift`. The precise pre-v4 disk actor is bundled in `Benchmarks/NonDecodeFourthPass/baseline/NativeThumbnailDiskCacheV3.swift`. Prior findings remain in the first three investigation reports.

[R2] [POSIX unlink/unlinkat](https://pubs.opengroup.org/onlinepubs/9699919799/functions/unlink.html): final-component semantics and error return behavior.

[R3] [Apple ImageIO: kCGImageSourceShouldCacheImmediately](https://developer.apple.com/documentation/imageio/kcgimagesourceshouldcacheimmediately): eager image decoding/caching option retained by the production helper.

[R4] [Apple FileManager directory enumeration](https://developer.apple.com/documentation/foundation/filemanager/enumerator(at:includingpropertiesforkeys:options:errorhandler:)): enumeration API contract. This motivates separating directory work but does not supply the numerical benchmark results.

All new numerical results come from the bundled receipts. They do not establish native macOS or whole-player performance.
