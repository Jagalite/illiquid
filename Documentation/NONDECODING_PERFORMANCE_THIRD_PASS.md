# Illiquid: non-decoding performance research — third pass

**Date:** October 15, 2026, America/New_York (receipts use October 16 UTC).
**Upstream baseline:** `854f8365750a0e4f046ab7015e01ca7a138ada40`, rechecked through connected GitHub.
**Comparison:** the delivered **v2 candidate versus v3**, not v3 versus the original unoptimized source.
**Status:** selected-source implementation and research candidate. No remote commit or PR. No full macOS application build or release qualification.

## Executive decision

This pass implements **per-field history no-op suppression**, avoids copying the unchanged duration dictionary during in-flight saves, and changes thumbnail inventory to **stream names and reject malformed entries before explicit metadata lookup**. It also fixes two correctness problems exposed by the tests: volume/speed setters reset history/restore preferences, and cache clearing could recursively delete a directory named like a thumbnail.

The biggest new win is eliminating work that has no state change: five identical saves at 100,000 history entries previously generated five complete JSON payloads and took a median **5,434.186 ms** through their flushes; v3 generates none and takes **0.098 ms** in the same isolated workload. That is **write elimination**, not faster physical storage. For genuinely changed progress while an old snapshot is in flight, 100 mutations improve **4.522 → 2.842 ms**, but whole-history encoding still dominates final completion.

Ordinary near-capacity thumbnail inventory improves only about **6%** here. Malformed-heavy directories improve **22–23×**, with much lower temporary allocation traffic. The full inventory remains on the first disk-access path; this is not a complete cold-preview solution.

A separate SQLite progress-table prototype demonstrates page-local updates, batched transactions, and process-kill recovery. **It is not integrated into Illiquid and is not feature-complete.** The container filesystem reports **`fsync=volatile`**, so its submillisecond timings are not valid evidence of physical SSD/durable-commit performance. This limitation also prevents interpreting the Foundation/defaults timings as storage-hardware benchmarks. The kernel documents omitted synchronization to the upper filesystem for this mount mode [A1].

**Recommendation:** retain the focused implementation for Mac qualification, repair duplicate-digest disk accounting next, and move the larger persistence investigation toward a transaction-based per-record design with a deliberate migration plan. Do not claim a whole-player speedup, large resident-RAM reduction, or completed SQLite migration from these results.

## 1. Experiments and dispositions

| ID | Experiment or finding | Evidence | Decision |
| --- | --- | --- | --- |
| E13 | Skip identical history/settings/version/restore mutations using only affected fields | Actual store, five modes at 1k/10k/100k; callback and payload counts | Implemented candidate; do not change checkpoint cadence or schema |
| E14 | Avoid assigning unchanged duration while immutable snapshot is in flight | Actual store allocation interposer and timing | Implemented; changed-value total persistence remains serialization-bound |
| E15 | Preserve preference flags through volume/speed changes | v2 fails targeted regression; v3 reload preserves opt-out and restore policy | Correctness fix included |
| E16 | Stream shallow disk inventory and reject malformed ASCII names early | Seven cases, five process samples per variant | Implemented; modest normal-cache result, strong malformed-directory result |
| E17 | Reject non-file entries and use nonrecursive cache deletion | Initial and post-inventory directory replacement cases | Correctness fix included; not a blanket hostile-filesystem defense |
| E18 | Replace whole-document progress writes with a local transaction table | Separate progress-only SQLite prototype, 18 observations, rollback/readers/reopen/process kills | Feasible direction; no production provider or migration yet |
| E19 | Check existing physical-file accounting edge cases | Two files for one digest, plus 8,256-file capacity check | Duplicate defect confirmed **and remains open**; capacity/tier checks pass |
| C01 | Five genuinely changed saves with a flush after each | v3 medians 2–7.5% slower in this small cohort | No general speedup; native non-regression qualification required |
| C02 | Empty/all-valid disk inventory allocation controls | Empty slightly slower; all-valid requested-byte volume essentially unchanged | Do not generalize pathological gains or claim universal RAM reduction |

Whole-history equality checks, direct lookup before inventory, a rewritten SwiftUI architecture, lower cache budgets, and changed refresh rates were not implemented or performance-tested in this pass. No decoder, renderer, audio, subtitle-output, or image-quality algorithm changes were made.

## 2. Provenance, scope, and measurement protocol

The run used **Linux x86-64, Swift 6.2.1, glibc 2.41**, on a shared host reporting **Intel Xeon Platinum 8573C**. That is not the AMD host described in older reports. Use the new paired v2/v3 cohort, not cross-report timing ratios. Primary Swift binaries use `-O -swift-version 6 -warnings-as-errors`. Host activity was not quiesced and OS caches were not purged.

The original v2 source tree was reconstructed from the attached bundle. New baseline copies are byte-identical to its two changed source files. The same v2 writer, instrumentation, and value types are used by both store variants. The existing v2 cache/mailbox is held constant for disk-inventory comparisons. Earlier optimizations are not credited again.

There are **254 new completed timing/allocation observations**: 130 actual-store timings, 70 inventory timings, 24 separately metered store runs, 12 separately metered inventory runs, and 18 SQLite prototype runs. Baseline/candidate process order alternates within each comparison round. Histories of 1k and 10k have five samples per group; 100k has three. Inventory has five; allocation and SQLite groups have three. Minima/maxima and individual rows are retained; these are not p95/p99 interaction statistics.

Two history-driver invocations hit an execution wall-time limit. Completed rows were saved and the remaining runs resumed with verified identical source and executable hashes. There are 130 unique completed history rows and no duplicate identities. Interrupted observations are not included; no completed outliers were removed. The final original `summary.json` covers the last requested 100k subset; `all-groups-summary.json` aggregates all 30 groups.

The exact unmetered inventory source is preserved under `timed-sources`. Its final source differs only in a comment clarifying explicit versus possible internal FileManager metadata work. A non-comment-line comparison and both hashes are included. Metered inventory and final integration tests used the clarified file. No executable statement changed between those inventory cohorts.

All inputs are synthetic UUID-isolated fixtures. No installed app preferences, user media, mounted NAS, or shared production database was modified. This is a selected-source checkout, not a full application build. Storage receipts establish callback/logic completion, not power-loss durability. The disclosed volatile overlay is especially important for SQLite interpretation [A1].

## 3. History: avoid no-op writes and unnecessary dictionary copies

### Implementation

V2 already deferred snapshot capture until the serial writer was ready. V3 checks the specific affected value before mutating its dictionary. An identical duration assignment is avoided even when position changes. Other checked operations include individual position, completion, missing-position removal, last-watched and restore targets, per-file settings, and unchanged media versions. Optional absence remains distinct from an explicitly stored zero; file/folder restore-target kinds remain distinct.

`mutateIfChanged` preserves the unreadable-history and disabled-history admission guards and uses the existing deferred snapshot factory when a mutation is meaningful. Bulk clear/reset operations deliberately remain unconditional. Preferences compare their small value, not the full history. There is no scan of all history records to discover a no-op.

A synchronized write-status flag retains the ability to resubmit after a known callback failure, even when the next accepted setter provides an unchanged value. The writer updates it outside the store lock. Snapshot capture remains short and synchronized; encoding/defaults I/O still happens outside the store lock. Tests cover failure reporting and recovery after correcting an unencodable value. The unchanged-infinity case confirms errors remain visible, not an independent count of failed encoder invocations.

### Five identical saves with explicit flushes

Each fixture is seeded, loaded, primed with the current value, and flushed **before** timing. The loop repeats that same accepted value five times, flushing after each call. The baseline does unnecessary serialization; the candidate sees no new state to persist.

| Entries | v2: five identical saves + flushes | v3: same workload | History callbacks, v2 → v3 |
| ---: | ---: | ---: | ---: |
| 1,000 | 47.855 ms | 0.051 ms | 5 → 0 |
| 10,000 | 502.275 ms | 0.067 ms | 5 → 0 |
| 100,000 | 5,434.186 ms | 0.098 ms | 5 → 0 |

At 100k, v2 passes **46,254,195 cumulative JSON bytes** to history defaults callbacks in the measured interval; v3 passes zero. This is application serialization/callback volume, not a claim about flash writes. `UserDefaults` and the filesystem may buffer or coalesce work. Existing pending changed values are still flushed; successful suppression is not an excuse to drop an outstanding required write. Apple's guidance distinguishes logical and physical I/O and recommends reducing repeated serialized-document writes [A2].

The burst-only identical-value cases also eliminate their one redundant callback. A no-op still normalizes its URL, performs field comparisons, and acquires locks; it does not become allocation-free. Its exact application frequency is unmeasured. The controller's roughly ten-second position-delta checkpoint condition from the previous audit must not be confused with this deliberately repetitive workload [S3].

### Genuinely changed values during an in-flight write

The test gates an actual defaults callback after its JSON encoding, preserving the immutable snapshot, then performs 100 new positions with the same duration. The gate is released and all pending work is flushed. Both variants perform the initial and latest callbacks; none is omitted.

| Entries | v2: 100 mutations, ms | v3: 100 mutations, ms | v2: through final flush, ms | v3: through final flush, ms |
| ---: | ---: | ---: | ---: | ---: |
| 1,000 | 0.657 | 0.619 | 18.127 | 18.105 |
| 10,000 | 0.906 | 0.777 | 176.477 | 175.876 |
| 100,000 | 4.523 | 2.842 | 1,895.148 | 1,880.116 |

At 100k the mutation-only reduction is about **37%**. Final completion changes little because whole-history serialization is still expensive. The gate is a controlled callback boundary, not an emulation of a stalled network filesystem. The mutation total is a sum over 100 calls, not an individual-input latency bound.

### Negative control: force every changed update to be persisted

Five different values, with a completed flush after each, intentionally remove the opportunity to coalesce or suppress writes:

| Entries | v2: total ms | v3: total ms |
| ---: | ---: | ---: |
| 1,000 | 47.246 | 48.186 |
| 10,000 | 518.230 | 557.111 |
| 100,000 | 5,380.590 | 5,482.495 |

V3 has **higher total medians in all three groups**: about 2.0%, 7.5%, and 1.9%. The number of callbacks and payload sizes match. Shared-host variability and small cohorts limit attribution, but the result is not a demonstrated speedup and must not be omitted. The extra field checks are not free. Recheck this control on Apple hardware before merging; a reproducible app-level regression would justify narrowing or revising the checks.

### Allocator evidence from the actual store

The separately instrumented 100k in-flight loop measures the actual URL-normalizing store, not only the earlier two-dictionary kernel:

| 100 updates while one write is in flight | v2 requests / requested bytes | v3 requests / requested bytes |
| --- | ---: | ---: |
| Identical progress values | 2,302 / 12,838,676 | 2,300 / 190,100 |
| New positions, unchanged duration | 2,302 / 12,838,676 | 2,301 / 6,514,388 |

Two large copy allocations disappear for no-ops; one disappears when only the position changes. Remaining requests include path/normalization work. The requested-byte reductions are about **98.5%** and **49.3%**, respectively. These counts repeat across three metered samples per group.

The glibc interposer counts successful malloc/calloc/realloc requests and cumulative requested sizes. It does not subtract frees or track every allocator/mapping. It is **not live or peak heap, RSS, physical footprint, compressed memory, or GPU memory**. No 12.6 MB steady-state app-RAM saving is claimed. Metered timing is not mixed into the primary tables.

## 4. Preference correctness uncovered during performance work

The original volume and playback-speed setters constructed a fresh `PlaybackPreferences` value without passing `remembersPlaybackHistory` or `restoresSessionPaused`. Both constructor defaults are true. Consequently, changing either control could silently undo a user's history opt-out and restore-paused choice [S1].

The new implementation changes only the intended field and sanitizes the resulting existing value. A targeted test starts with both flags false, changes volume/speed, attempts to save history, flushes, and reloads. It preserves both flags, language choices, and the absence of a history write. The same targeted test against v2 fails four assertions; its failing receipt is included. The full updated suite passes in debug and release.

This is a correctness fix, not a performance score. The mixed-operation parity corpus does not demand parity with this bug. It validates the pre-existing progress/version/settings behavior separately; the new preference test establishes the deliberate corrected behavior.

## 5. Thumbnail inventory: streaming, validation, and nonrecursive cleanup

### Changes and limits

The previous disk loader first created a URL list, then inspected properties of cache-like names before rejecting invalid digest characters. V3 uses a shallow enumerator, validates the exact `b-`/`f-` plus 64 ASCII hexadecimal bytes plus `.jpg` format, then explicitly requests size/date/type metadata only for accepted names. Both hex letter cases remain accepted; invalid Unicode lookalikes do not. Regular nonsymlink files are required.

The implementation still completes inventory before enforcing budgets. **It does not eliminate first-access inventory, bound the initial valid-entry index to a fixed peak, or guarantee zero FileManager-internal metadata I/O.** More aggressive direct lookup/index changes need separate accounting and ordering work.

### First inventory results

Five fresh processes per variant/case; fixtures are created immediately beforehand, so OS caches are warm. Valid-name fixtures contain small synthetic bytes, not decoded JPEGs. No image codec executes inside inventory. Times include the actor call and its actual Foundation enumeration/metadata/bookkeeping, not video extraction or visible preview publication.

| Fixture | v2 inventory median | v3 inventory median |
| --- | ---: | ---: |
| Empty | 0.610 ms | 0.751 ms |
| 1,000 recognized regular files | 63.651 ms | 59.913 ms |
| 8,191 recognized regular files | 527.020 ms | 495.126 ms |
| 8,191 entries, about 10% valid | 515.871 ms | 74.116 ms |
| 8,191 malformed cache-like names | 506.561 ms | 22.337 ms |
| 32,768 malformed cache-like names | 2,029.348 ms | 86.377 ms |
| 32,768 unrelated names | 80.230 ms | 60.695 ms |

The ordinary 8,191-entry case improves from **527.020 to 495.126 ms**, roughly 6.1%, but still takes about half a second in this environment. The malformed-heavy results are much stronger, around 22.7× and 23.5×. The empty control is approximately 0.14 ms slower. These distinctions prevent presenting pathological-file gains as a 23× ordinary hover improvement.

For 8,191 malformed entries, separately metered requested bytes fall **170,346,817 → 12,167,174**, about **92.9%**. In the all-valid case, allocation request count decreases, but requested bytes change **172,187,137 → 172,833,634**—slightly higher, not a memory-volume reduction. Extra file-type checking and the retained index still cost work. Point-in-time Linux RSS before/after samples remain in the raw data, but do not establish peak memory, sustained resident savings, or macOS footprint.

### Two deletion cases now fail safely

A directory whose basename looks like a cache JPEG was previously indexed and recursively deleted by `FileManager.removeItem`. Separately, a known regular image file could be replaced with a directory after inventory; clearing then recursively removed its contents. Both cases were reproduced against v2 with a sentinel file, using only disposable fixtures.

V3 excludes directories and static symlinks from inventory. Actual image removal uses `unlink`, not recursive directory deletion. The late-replacement test retains the directory/sentinel and reports an unsuccessful clear instead of claiming success. Missing files remain successful removals. POSIX specifies removal of the final symlink itself, not its target, and defines unsuccessful unlink behavior [A3]. This change is not a claim to defend every parent-directory symlink race or hostile concurrent filesystem modification; native macOS behavior still needs qualification.

### Known remaining defect: duplicate physical files for one digest

A separate untimed diagnostic creates `b-<digest>.jpg` with 128 bytes and `f-<digest>.jpg` with 256 bytes. Both v2 and v3 index one entry, account only **128 of 384 bytes** in these runs, and return clear-success while leaving the foreground filename behind. Enumeration order can affect the winner; this report does not prescribe that order.

**This existing defect is not fixed by v3.** The diagnostic and results are included explicitly, not hidden in passing-test totals. Next work should distinguish physical entries from logical digest identity, prefer foreground state deterministically, account for both files until successfully reconciled, and report cleanup failures correctly. That is also a prerequisite for a trustworthy direct-lookup/partial-inventory redesign.

An additional 8,256-file check verifies the unchanged count-cap behavior: both variants end at 8,191 entries and preserve all 64 foreground entries while trimming background entries. This does not clear the duplicate case or prove every byte-budget/race scenario.

## 6. SQLite: useful direction, not a finished migration or hardware benchmark

The proof of concept uses **Python's sqlite3 binding** to native SQLite, a single `progress` table keyed by path, WAL, `synchronous=FULL`, explicit transactions, and a nominal 2 MiB page cache. It implements sticky completion and changed-field upserts. It neither hydrates all history into Swift dictionaries nor supports Illiquid's complete persistence contract.

At each of 1k, 10k, and 100k rows, 100 updates to one hot record in one transaction create a **4,152-byte WAL file** in the measured interval. Five changed updates with five commits create **20,632 bytes**. All 18 timing samples preserve the final value/row count on reopen; identical SQL updates show zero changed rows and zero WAL-file growth.

Raw median update-plus-commit times for 100 updates are approximately **0.260, 0.256, and 0.260 ms** by size. Those numbers are retained for transparency, **not used as a performance claim against the JSON store**. The filesystem's `fsync=volatile` mode omits upper-layer synchronization [A1]. The bindings, data shapes, supported features, transaction boundaries, and hydration scope also differ. There is no meaningful “SQLite is N× faster” calculation from these two experiments.

The justified finding is narrower: this progress-only design can update a small set of database pages without serializing all unrelated progress records. WAL byte counts are logical file growth, not total filesystem/SSD traffic, and do not include all later checkpoint work. The 2 MiB setting is a nominal SQLite cache budget, not process RSS.

Logical tests execute 10,000 deterministic updates with 100 matching model receipts, rollback, separate-reader visibility, and ten child-process kills. Five kills before commit restore the old value; five after commit retain the new value; integrity checks report `ok`. **The operating system remains alive**, so these are process-recovery tests, not host-crash, sudden-power-loss, or production-migration qualification.

A production database should live in the app's local support directory, even when media files reside on a NAS; SQLite WAL does not work across network filesystems/shared hosts in the ordinary WAL design [A4]. Connection ownership, bounded queues, admission, errors, transaction ordering, and migration remain application responsibilities, not benefits automatically delivered by choosing SQL.

## 7. Validation completed and not completed

**Executed:** 26 actual-core XCTest cases in both release and debug, including 14 new cases. Coverage includes no-op versus real writes, completion thresholds and rewatches, version/settings/restore behavior, blocked snapshots, concurrent distinct changes, failure reporting/recovery, explicit unreadable-history reset, preferences, and prior deferred-capture lock/lifetime contracts. Repeated build configurations are not different tests.

**Executed:** 2,319 candidate inventory assertions, including exhaustive single-byte filename substitutions and real filesystem scenarios; 9 baseline checks record prior behavior. Five mailbox tests, including 5,000 reserve-versus-evict races, and 196 candidate preview-adapter checks pass. The original ranking/cache harness also passes: 4,218 ranking comparisons and its existing cache/survivor checks. These overlapping assertions are not an additive whole-app test count.

**Executed:** 10,000 mixed store operations per variant with 200 matching effective reload states, comparing the pinned upstream store with the cumulative candidate. As before, completed-set ordering and the obsolete embedded preferences copy are normalized to effective reload behavior. This is not JSON byte identity or parity with the deliberately fixed volume/speed bug. SQLite's separate test file records 123 assertions and the ten process-kill outcomes.

**Authored, syntax-parsed only:** five `ThumbnailInventoryRegressionTests` cases in the native test target. The two changed source files also syntax-parse. The actual Darwin/ImageIO application module has not been SDK-typechecked here. Inventory timing uses real filesystem logic with image imports adapted for compilation; existing portable preview tests use synthetic images and are not native-image qualification.

**Not performed:** complete repository build/test suite, architecture checker, release/signature verification, macOS Instruments, real UI scrubbing/resize/hover, physical footprint/energy/GPU measurements, actual NAS fault injection, full database migration, and host/power-loss recovery. Existing v2 signposts cover the history and inventory paths; no additional per-frame instrumentation or accumulating runtime log was added.

## 8. Recommended next implementation sequence

### First: qualify and finish the focused candidates

On a supported Mac, run the complete native core/cache/app suites, then matched release builds with fixed fixtures and isolated histories/caches. Record actual controller call frequency, main-thread lock/mutation intervals, total write/flush costs, File Activity, allocation generations, and physical footprint. Include the changed-value negative control; do not set Linux microbenchmark medians as release thresholds.

Repair duplicate physical-entry accounting before using an incomplete inventory for lookups or eviction. Preserve foreground reservations, in-flight encoding/clear epochs, malformed-file isolation, and nonrecursive deletion. Measure empty, normal, full, duplicated, and externally modified caches. The current complete scan is still a responsiveness target, but an incorrect fast index is not acceptable.

### Second: make progress persistence proportional to changed records

Prototype a Swift provider behind the existing persistence-facing API. First model progress/completion, per-file settings, content versions, replacement archives, last-watched/restore targets, and preference precedence. Preserve absent versus zero, sticky completion and rewatch position, explicit clears, disabled history, and error reporting. Group related source-commit mutations in one transaction with one serial writer and a bounded pending set; define what happens when that set fills.

Keep synchronous reads correct during migration/hydration. A minimal active-file/resume index can help startup, but an empty placeholder must never overwrite the complete history. Choose a clear state machine for uninitialized, importing, ready, failed/read-only, and explicitly reset states. Keep the legacy data until transaction, validation, and restart markers establish a completed import. Test repeated launch, interrupted import, corrupt source, schema upgrade, downgrade/re-upgrade, and close/quit while writing.

Measure on real APFS storage with a documented synchronization policy. Compare the **same production Swift behavior and fixtures**, including all relevant tables and final shutdown, not a Python progress-only table against the full JSON store. Add process-kill tests, then appropriate dedicated-host crash/power tests only in an isolated qualification environment. Prefer a small measured pilot over declaring the storage rewrite ready from this proof of concept.

### Third: trace actual UI costs

Continue with real SwiftUI update causes and hitch intervals for scrubbing, sidebar scrolling, window resizing, and close/reopen. The existing field-level projection is not presumed defective. Keep decoder cost, UI feedback, image-ready time, and actual presentation latency separate. Apple recommends profiling logical/physical writes and consolidating related changes; those recommendations motivate experiments, not replace measurements [A2].

## 9. Reproduction and delivery

The cumulative patch contains v1, v2, and v3 against the pinned upstream baseline. The v3-only patch applies **after the exact v2 candidate**. They are alternatives: **do not apply both**. This delivery is a selected-source implementation/evidence tree, not a complete repository or a pushed branch.

```sh
git status --short
git apply --check /path/to/illiquid-nondecoding-v3-cumulative.patch
git apply /path/to/illiquid-nondecoding-v3-cumulative.patch
```

`Benchmarks/NonDecodeThirdPass/README.md` gives the exact selected-source commands, requirements, expected-failure reproduction, and native gates. Its `evidence` directory holds raw rows, complete and original subset summaries, test logs, environment/mount evidence, manifests, and the open edge-case diagnostic. Existing evidence is retained separately. Final package validation records application/reversal and output-file hash comparisons; it does not certify the app build.

## References

[S1] Pinned source: `Sources/IlliquidCore/Persistence/PlaybackPersistenceStore.swift` (especially original volume/speed setters) and `PlaybackPreferences.swift`. The original Git blob for the store is `a05aa65776b753acf9ecac8640f5eb98c1a6e0cd`.

[S2] Pinned source and v2 candidate: `Sources/IlliquidNativePlayback/Media/NativeThumbnailDiskCache.swift`; new baseline copies and exact timing source are bundled. The original upstream disk-cache blob is `91a5e3bad208b658fe6653f07dbb81ae53217ae1`.

[S3] [Pinned controller checkpoint condition](https://github.com/Jagalite/illiquid/blob/854f8365750a0e4f046ab7015e01ca7a138ada40/Sources/IlliquidPlayer/Player/PlaybackController.swift#L2011-L2018). Prior reports remain under `Documentation/NONDECODING_PERFORMANCE_INVESTIGATION.md` and `Documentation/NONDECODING_PERFORMANCE_FOLLOWUP.md`.

[A1] [Linux kernel: OverlayFS, synchronization and volatile mount](https://www.kernel.org/doc/html/latest/filesystems/overlayfs.html#volatile-mount).

[A2] [Apple: Reducing disk writes](https://developer.apple.com/documentation/xcode/reducing-disk-writes).

[A3] [POSIX: unlink/unlinkat](https://pubs.opengroup.org/onlinepubs/9699919799/functions/unlink.html).

[A4] [SQLite: Write-Ahead Logging](https://www.sqlite.org/wal.html).

New numerical claims are derived from the bundled receipts, not from external documentation. Raw observations and explicit scope take precedence over rounded headline numbers.
