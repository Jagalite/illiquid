# Illiquid: non-decoding memory and responsiveness investigation

**Date:** October 15, 2026 (America/New_York)
**Baseline:** `Jagalite/illiquid` commit `854f8365750a0e4f046ab7015e01ca7a138ada40`
**Status:** implementation candidate, portable experiments completed; macOS application qualification outstanding. No remote commit or pull request was created by this investigation.

## Executive assessment

There is a worthwhile, demonstrated optimization in thumbnail scheduling **without touching video decoding or reducing functionality**. Ranking was repeatedly constructing and normalizing Foundation URLs for every candidate/excluded-folder pair. The candidate normalizes exclusions once per ranking call, combines eligibility/scoring into one pass, and sorts one mutable collection.

Across seven fresh-process samples per variant, ranking 2,048 candidates took **12.957 → 4.747 ms with no exclusions**, **115.808 → 6.590 ms with 16 exclusions**, and **774.356 → 12.987 ms with 128 exclusions**. The last case is a 59.6× kernel speedup. Cumulative `malloc`/`calloc`/`realloc` request traffic for that case fell **444,086,303 → 2,487,746 bytes**, or 99.44%. These are actual measurements of the selected production Swift sources on Linux, not an estimate from complexity alone.

Three smaller cache changes are included: lowercase digest formatting without per-byte formatted strings; allocation-light background admission; and direct clearing instead of sorting everything during critical memory pressure. The patch also adds opt-in Instruments intervals and cache-resident counters, reproducible benchmark sources, raw receipts, and four macOS regression tests.

**Do not describe this as a 60× faster player or a 99% reduction in app RAM.** Ranking already runs in a detached utility task. Its reduced CPU/allocation work is useful, but fewer UI hitches, lower process footprint, and reduced energy are not measured here. The primary memory result is reduced transient allocation traffic, not live or peak bytes. No decoder, pixel conversion, presentation, audio, or subtitle-rendering algorithm was modified.

The next high-value investigations are foreground preview waits behind disk-cache inventory/promotion work, and large-history snapshot/encoding amplification. Both have concrete code paths to investigate, but their user-visible costs remain hypotheses in this report.

## 1. Evidence boundaries and provenance

The environment was Linux x86-64 on an AMD EPYC 9V74 host, with Swift 6.2.1 and `swiftc -O -swift-version 6 -warnings-as-errors`. The host was shared, not quiesced or thermally controlled. No Apple hardware, macOS frameworks, installed Illiquid application, Instruments traces, or real user media library were exercised. Foundation behavior and allocator costs differ between Linux and macOS; percentages cannot be transferred directly between them.

Selected files were read through connected GitHub. The branch head was confirmed separately. The locally reconstructed originals match Git's blob identities exactly:

| Original production file | Verified Git blob |
| --- | --- |
| `Sources/IlliquidCore/Player/ThumbnailPolicy.swift` | `e06088b51837491b6ff5975469453f34205020d8` |
| `Sources/IlliquidNativePlayback/Media/NativeThumbnailCache.swift` | `c97deee800b964e44ac02aaceb2ecd590770e41b` |

The repository is not fully checked out in this environment. This is a targeted source audit and experiment, not a whole-repository build or exhaustive audit. Other files were inspected through the connector, including the scheduler, disk cache, playback observation store, persistence store/writer, subtitle matcher, filename recognizer, package manifest, and relevant prior performance reports. Only the opening 210 lines of the large `PERFORMANCE_FOLLOWUP.md` were inspected; this report does not claim to supersede that entire document.

Reproduction assets are under `Benchmarks/NonDecodePerformance`. `evidence/manifest.json` contains compiler/platform details and original source hashes; `bundled-source-hashes.json` identifies relocated packaged files. Paths in the original command log describe the investigation workspace, not required installation paths.

The execution comprised **196 observations: 28 variant/workload groups with seven samples each**. The initial orchestration invocation hit a tool wall-time limit after eight complete ranking cases. Remaining cases resumed from unchanged binaries; allocation runs used separately instrumented builds of the same sources. No interrupted observation is included. Completed receipts were preserved, and `execution-notes.txt` records this interruption.

## 2. Experiment and decision register

| ID | Question / trial | Evidence obtained | Disposition |
| --- | --- | --- | --- |
| E01 | Can ranking avoid repeated URL normalization and intermediate arrays while returning identical order? | Nine workload pairs, seven repeats; 4,218 differential checks | **Implemented candidate.** Largest demonstrated gain. |
| E02 | Does E01 reduce allocator work, rather than merely moving cost? | Separate instrumented builds; three exclusion counts, seven repeats; cumulative request counts/bytes | **Confirmed in Linux harness.** Not a footprint result. |
| E03 | Can cache digest hex encoding avoid 32 formatted strings? | Seven repeated microbenchmarks; all 256 byte values plus varied sequence lengths | **Implemented candidate.** Full hashing/JSON/I/O timing not measured. |
| E04 | Can background admission avoid building a filtered image dictionary? | Actor-body logic tests with platform doubles; seven repeated actor-round-trip benchmarks | **Implemented candidate.** Protection and admission traces preserved. |
| E05 | Can critical pressure release residents without sorting/temporary image retention? | Ownership and counter assertions with mock images; warning-path survivor traces unchanged | **Implemented candidate.** No real-CGImage release latency or process-memory measurement. |
| E06 | Can the changed paths be profiled in the real app without permanent log accumulation? | Opt-in signpost helper compiled on Linux's disabled branch; macOS test syntax parsed | **Instrumented candidate.** Actual macOS branch/build/trace must be qualified. |
| R01 | Avoid foreground waits behind disk-cache inventory/promotion | Source inspection only | **Recommended experiment, not implemented or timed.** |
| R02 | Reduce full-history snapshot and JSON amplification | Source inspection and existing architectural constraints | **Recommended experiment, not implemented or timed.** |
| R03 | Rewrite SwiftUI or reduce refresh frequencies wholesale | Existing field-level publication; no new UI trace | **Not justified by current evidence.** Profile concrete invalidations first. |
| R04 | Purge all caches on every close / reduce cache defaults | Existing bounds and prior lifecycle qualification | **Not selected.** It changes warm behavior without new evidence of a benefit. |

There was no new A/B trial of a SwiftUI rewrite, SQLite migration, disk-cache index, smaller image budget, or lazy native graph. Those are explicitly not counted as implemented or failed experiments.

## 3. E01: thumbnail ranking

### Cause and implementation

`ThumbnailPreferences.bounded` already standardizes excluded folder paths, and `ThumbnailPolicy.Candidate.init` already standardizes candidate URLs. The old `ranked` method then called `excludesBackgroundGeneration` for every candidate, recreating and standardizing those same exclusion URLs repeatedly. It also produced separate eligible, scored, and sorted arrays and repeated parent-path derivation.

The replacement builds component-boundary-aware exclusion strings once, traverses candidates once, computes locality/score once per unique candidate, and sorts the mutable scored array in place. It preserves current/visible tiers, recency/locality weights, neighbor handling, stable ties, the requested limit, and the first duplicate's semantics. Importantly, an ineligible first occurrence still prevents a later duplicate from overriding it, just as before.

The complete ranked pool remains available when the scheduler requests it. Truncating to `videosPerPass` early would invalidate the scheduler's persistent pass cursor and reintroduce starvation below the repeated highest-priority prefix. A top-k shortcut was therefore not substituted. The change does not increase thumbnail decode concurrency or admit additional work by changing policy.

### Protocol

Fixtures contain 32, 256, or 2,048 candidate paths and zero, 16, or 128 nonmatching excluded roots. The nonmatching roots require scanning the full exclusion list and represent an expensive but valid case. Inputs include mixed recency and visibility; not every input necessarily becomes eligible. A deterministic date and source folder are supplied. The full ranked pool is requested.

Fixture construction and two warmup calls are outside timing. Each fresh process times 10 ranking calls for 32 candidates, three for 256, and one for 2,048. Baseline/candidate process order alternates across seven rounds. Checksums match between variants. Reported values are medians of each process's per-call mean; they are **not p95/p99 interaction latency**.

### Results

Milliseconds per ranking call:

| Candidates | Excluded roots | Baseline median | Candidate median | Speedup |
| ---: | ---: | ---: | ---: | ---: |
| 32 | 0 | 0.143 | 0.078 | 1.8× |
| 32 | 16 | 1.955 | 0.174 | 11.2× |
| 32 | 128 | 13.627 | 0.734 | 18.6× |
| 256 | 0 | 1.505 | 0.545 | 2.8× |
| 256 | 16 | 13.780 | 0.801 | 17.2× |
| 256 | 128 | 102.345 | 2.052 | 49.9× |
| 2,048 | 0 | 12.957 | 4.747 | 2.7× |
| 2,048 | 16 | 115.808 | 6.590 | 17.6× |
| 2,048 | 128 | 774.356 | 12.987 | 59.6× |

At 2,048/128, observed ranges were 770.674–831.014 ms before and 12.645–13.450 ms after. At 2,048/0 they were 12.074–13.562 ms and 4.295–6.703 ms. Every workload's median improved, including the default no-exclusion case. Small-folder absolute savings are correspondingly small; a large percentage there is not a perceptible-delay claim.

`ThumbnailBackgroundScheduler` already performs ranking in `Task.detached(priority: .utility)`. The result supports less preparation work and allocation contention, not a claim that a 774 ms main-thread freeze was removed. Actual scheduling frequency and concurrent UI pressure determine the app-level benefit.

## 4. E02: transient allocation traffic

The Linux-only `allocmeter.c` interposes `malloc`, `calloc`, and `realloc`, using glibc's underlying entry points. Counters enable immediately before the measured ranking loop and disable immediately after timing ends. Fixture construction, warmups, and output serialization are excluded. A small fixed timing-infrastructure overhead can be included equally in both variants.

The meter counts successful allocation requests and sums their requested sizes. It does not subtract frees, distinguish in-place reallocations, intercept every allocator family, or account for virtual-memory mappings. It is **not live heap, peak heap, RSS, physical footprint, compressed memory, CGImage pixels, or GPU storage**. Seven samples produced identical request totals for each variant/workload.

One ranking call with 2,048 candidates:

| Excluded roots | Request count: before → after | Requested bytes: before → after | Cumulative MiB: before → after | Byte-traffic reduction |
| ---: | ---: | ---: | ---: | ---: |
| 0 | 70,609 → 19,020 | 6,068,783 → 1,792,690 | 5.79 → 1.71 | 70.46% |
| 16 | 759,067 → 25,511 | 60,821,311 → 2,269,922 | 58.00 → 2.16 | 96.27% |
| 128 | 5,578,209 → 27,869 | 444,086,303 → 2,487,746 | 423.51 → 2.37 | 99.44% |

The conclusion is that E01 eliminates substantial temporary allocator traffic in this implementation/environment. **The application did not demonstrate a 423 MiB resident-memory saving.** Timings from these metered runs are retained in raw evidence but are not mixed into E01's unmetered timing table. Apple memory tools should establish real heap/footprint changes separately [A3].

## 5. E03–E05: smaller cache optimizations

### Hexadecimal encoding

`NativeThumbnailCache.Key.digest` continues to use the same sorted-key JSON and SHA-256. Only the conversion of digest bytes to lowercase hexadecimal changes. A small byte buffer replaces a formatted string per byte. There is no new cache format, renderer version, hashing algorithm, persistent key, or media identity policy.

The microbenchmark formats 32-byte sequences, consuming the output so it cannot simply be eliminated. It includes seven fresh processes per variant, each formatting 10,000 sequences. Median per operation was **33.692 → 1.160 microseconds** (about 29×), with observed ranges 33.174–35.931 and 1.080–1.300 microseconds. There is no explicit hex warmup; first-use costs are amortized over the 10,000 operations identically.

This is a small absolute saving. It does not measure JSON encoding, SHA-256, file identity lookup, filesystem access, JPEG decoding, or a complete hover preview. The Linux cache double's fake SHA function is not cryptographic validation. Exhaustive byte-format checks ran here; the added macOS suite compares complete keys with the real legacy CryptoKit expression.

### Admission without a temporary dictionary

Background admission previously filtered resident entries into a dictionary to calculate reclaimable bytes. The candidate uses a fast path when capacity already exists, otherwise sums eligible residents directly. Foreground images and the active storyboard remain protected from speculative eviction. Image-count and byte limits are unchanged.

Invalid/nonfinite or out-of-domain dimensions are now rejected without a trapping floating-point-to-integer conversion. The positive, valid-size estimate retains the existing truncated-dimension calculation.

With 96 logical resident images and a 128 MiB budget, a repeated actor-call harness measured **36.273 → 26.852 microseconds** per admission round trip, approximately 26% less time. Ranges were 33.771–47.567 and 23.985–32.963 microseconds. These measurements include executor scheduling and use mock images; they are not isolated CPU instruction costs or full preview timings. The larger reason to keep the change is avoiding unnecessary dictionary allocation and temporary image references while preserving decisions.

### Critical pressure

When every resident must be removed, eviction ordering is unnecessary. The candidate directly clears the image dictionary and storyboard set without retaining capacity and sets resident bytes to zero. The warning-pressure path still halves the byte footprint using the existing priority/age ordering. Revision advancement and pending-write clearing remain in place.

The test double proves that a cache-only owned image reference is released and that the cache can accept new images afterwards. It does not prove when the macOS allocator returns pages, or that all references to actual pixel storage disappear. A caller, an already-running physical writer, or a framework can legitimately retain an image independently of the resident dictionary. Disk content and preferences are not purged by this change.

The default resident image budget remains **16 MiB**, with a **96-entry** ceiling and bounded preferences. No steady-state cache-budget reduction is claimed. There is no measured before/after critical-pressure duration in this investigation.

## 6. Correctness and integration status

**Executed:** 4,218 ranking differential comparisons against the exact baseline logic. These include deterministic mixed candidates, duplicates, Unicode paths, spaces/percent signs, component boundaries, root exclusion, remote URLs, clamped preference values, priorities, recency, and negative/zero/large requested limits. Larger-pool cases also compare both a small prefix and the entire ranking. This is substantial regression coverage, not a formal proof for every Foundation URL behavior on macOS.

**Executed:** 1,868 candidate cache/hex checks and 1,598 corresponding baseline cache checks. Their **1,960 emitted decision/survivor trace rows are identical**. Budgets 8/16/128 MiB, foreground/background mixtures, storyboard protection, 96-entry pressure, warning survivors, critical clearing, reinsertion, invalid dimensions, and mock reference release are covered. Test counts overlap by design and must not be added together as independent tests.

The portable cache harness compiles the production actor body with only platform imports removed, substituting explicitly named doubles for CGImage, file identity, CryptoKit, the blocking reader, and the disk actor. It **does not qualify** ImageIO, real disk promotion/reload, stale in-flight I/O, physical writer races, real pixels, or macOS memory-pressure delivery.

**Authored, syntax-parsed only:** four native `NonDecodePerformanceTests` tests for byte formatting, full JSON/CryptoKit key compatibility, invalid dimensions, and critical clearing while an external CGImage remains usable. They have not been typechecked against the macOS SDK or executed. Existing `NativeThumbnailCacheTests` include real disk/pressure behaviors and should run unchanged, along with the broader app/scheduler suites.

**Not executed:** a full SwiftPM application build, repository architecture checker, complete repository test suite, release bundle/signature verification, Instruments capture, UI automation, energy/GPU/WindowServer measurement, NAS fault injection, or live PiP/sleep/wake testing. Those are release gates, not assumed successes.

## 7. Instrumentation added

`Sources/IlliquidCore/Utilities/NonDecodePerformance.swift` exposes signpost intervals under subsystem `com.illiquid.performance`, category `NonDecode`, following Apple's OSSignposter API [A1]. Call sites currently cover:

| Marker | Meaning |
| --- | --- |
| `ThumbnailDigest` | JSON, SHA-256 and hexadecimal key conversion as a whole |
| `ThumbnailAdmission` | Cache admission decision body; excludes waiting to enter the actor |
| `ThumbnailMemoryPressure` | Resident trim/clear body |
| `ThumbnailResidentMemory` | Event carrying resident dictionary byte count and image count at selected mutations |

It requires all three guards: bundle ID `com.example.IlliquidBenchmark`, `ILLIQUID_ENABLE_BENCHMARK_OVERRIDES=1`, and `ILLIQUID_BENCHMARK_NONDECODE=1`. These match the current source's benchmark identity rather than legacy names in older documents.

There are no media-path payloads, per-frame timers, unbounded retained samples, or synchronous stderr messages in this helper. Disabled calls return without starting intervals; that does not mean mathematically zero function/branch overhead. The macOS-specific branch still requires SDK compilation and a real trace check. Run resource comparisons with the opt-in **off**, then separate diagnostic captures with it on.

Resident counters exclude externally retained images, in-flight writer images, dictionaries/metadata, disk buffers, framework caches, and GPU memory. They are observations at selected mutation points, not a continuously sampled whole-app gauge. The ranking policy remains pure and uninstrumented in production; its harness measures it externally. Instrument the scheduler's preparation interval at the shell boundary in a later macOS diagnostic pass rather than adding wall-clock reads to the policy.

## 8. Prioritized remaining investigations

### P1: foreground previews must not await avoidable disk housekeeping

The disk actor's `image` calls `loadDisk`, which inventories the directory and reads metadata before lookup. A RAM hit that needs promotion can also await `disk.promote` before being returned to the caller. This is a credible source of cold-preview or periodic-preview tail latency, but no latency for these paths was measured here.

Use a disposable cache with empty, 1k, 8k, and oversized/unrecognized file sets. Split first request into actor queue wait, inventory, key generation, file read, JPEG decode, promotion, and publish. Test a blocked disk operation while requesting an already resident image. Distinguish first disk access after process launch from a truly cold OS cache.

Candidate designs: immediate resident delivery with ordered asynchronous metadata promotion; direct digest lookup before complete inventory; and bounded/streaming directory indexing. Keep foreground protection effective before any speculative eviction. Test promotion while encoding, clear/configure during indexing, stale epochs, source replacement, malformed files, duplicate on-disk digests, and errors. An actor makes access serialized; it does not make a synchronous filesystem call nonblocking. Preserve bounded physical I/O instead of spawning unbounded tasks [A2].

A persistent LRU/heap or low-water batch eviction might reduce repeated full sorting at disk capacity. Profile first: metadata work and storage latency may dominate, and batch trimming changes cache-hit policy. Do not combine that policy change with the immediate resident-hit fix in one unmeasured experiment.

### P1: history mutation and persistence amplification

`PlaybackPersistenceStore.mutate` holds a lock, changes `StoredState`, and submits a value snapshot. The writer already coalesces pending work and performs JSON encoding off the caller's executor. However, retained pending/in-flight snapshots can make subsequent dictionary mutations copy-on-write, and completed writes encode the whole state. Preferences already use a separate write path. These are code-level mechanisms to measure, not a demonstrated UI regression in this pass.

Measure 1k/10k/100k histories: mutation/lock duration, outstanding snapshots, allocation traffic, encoding time, bytes written, and final flush latency. Include an actively encoding writer and a deliberately blocked test destination. Test repeated checkpoints, completion transitions, source switches, and identical-value submissions separately. Do not use an O(history-size) whole-state equality check to skip a small no-op mutation.

Consider batching related in-memory mutations, dirty-record tracking, a transactional journal/database, and a minimal resume index with explicit full-history hydration. A SQLite migration is a larger durability project, not an automatic performance fix. Preserve unreadable-history protection, version matching, sticky completion, settings migration, ordering of the latest checkpoint, shutdown flush/error reporting, and recovery after interrupted migration. A partially loaded store must never overwrite complete saved history. Apple's disk-write guidance supports measuring and reducing unnecessary writes, not dropping required durable updates [A5].

### P2: SwiftUI observation, sidebar and scrubbing

`PlaybackViewStore` already publishes changed fields rather than making every position tick invalidate an entire shared snapshot. `ExternalSubtitleMatcher` already has an indexed candidate search, and `MediaNameRecognition` already compiles regexes once. Reimplementing these existing optimizations is not a recommendation.

Use a valid SwiftUI update-cause trace for hover, continuous scrub, sidebar scrolling/toggling, resize, and playlist replacement. Separate body computation, layout, commit, render, and event-to-feedback intervals. Target repeated row projection, formatting, identity churn, image publication, or broad dependencies only when stacks and update causes identify them. Apple distinguishes expensive updates from unnecessary update frequency [A4].

Keep the display responsive without masking work by dropping meaningful state changes. Do not arbitrarily reduce UI frequency, remove animation, disable subtitles, or return stale previews to improve a synthetic score. Retain instant control feedback separately from seek completion: a responsive scrub indicator is not proof that the requested video frame was displayed.

### P2: ownership across lifecycle transitions

Run repeated mixed-source cycles with and without external/text/bitmap subtitles, PiP, hidden windows, and close/reopen. Compare post-settle allocation generations and retained object graphs, not just one RSS number. Repeat with warning/critical pressure and pending preview operations. Look for continuing growth and clear owners before calling retained framework caches a leak.

Avoid unconditional full teardown on close or cutting every cache budget. Those may reduce warm residency while increasing first-open latency and repeated allocation work. The existing lifecycle reports already discuss such tradeoffs; this pass does not overturn their decisions. Preserve newly merged visibility and fairness behavior at the pinned baseline.

### Lower priority / explicitly not selected

Do not cache file identity indefinitely to avoid `stat`: content-version invalidation is a correctness boundary, especially for files replaced in place. A source-session identity cache would need a reliable invalidation contract and slow-storage measurements. Do not increase thumbnail concurrency to hide latency: extra speculative work can compete with the player. Do not modify video decoding as part of this patch.

## 9. macOS qualification and acceptance plan

Use separate release baseline/candidate bundles, identical production playback policies, fixed fixtures and window dimensions, isolated preferences/cache/history, and recorded build/dependency hashes. Never point destructive cache fixtures or fault-injection tooling at the installed app's data. Record machine, OS, display refresh, storage, power/thermal state, source/fixture hashes and exact opt-ins.

| Scenario | Required observations | Acceptance / correctness boundary |
| --- | --- | --- |
| Empty app, paused media, normal playback | Process CPU, physical footprint, wakeups, main-thread activity | No new steady idle work; baseline/candidate noise characterized |
| Ranking matrix from this report on Apple hardware | Wall time and allocation generations | Same outputs; improvements repeat with macOS Foundation |
| Warm RAM hover / first disk hover / uncached hover | Request-to-image-ready, actor queue wait, main-thread feedback | Separate cases; no wrong-source image or stale publication |
| Scrub/resize/sidebar under preparation load | Hitch counts, frame/update intervals, input feedback | Lower measured hitch cost or non-regression; do not infer display latency from IPC acknowledgement |
| Full protected cache, warning and critical pressure | Admission/eviction counts, resident bytes, retained owners | No protected speculative eviction; stale operations do not undo pressure boundaries |
| 1k/10k/100k history, source switch and final Quit | Lock/update/encode/flush timing, writes, final stored position | Responsiveness without skipped writes or lost checkpoints |
| Repeated close/reopen, PiP, hidden/sleep/wake | Post-settle allocation generations and continuing growth | Warm behavior preserved; no wasted hidden preview work or persistent growth without explanation |

Choose device-specific budgets before collecting the acceptance run. Suggested investigation triggers—not measured guarantees—are multi-millisecond main-thread work during continuous interactions and any repeated frame-budget overruns. At 60 Hz the complete frame interval is about 16.7 ms; at 120 Hz about 8.3 ms, and application work only receives part of it. Apple's guidance recommends keeping continuous-interaction work very small [A2].

Use substantially more interactions than seven when reporting p95/p99 UI tails. Keep diagnostic signposts, allocation stacks, or heartbeat sampling out of the primary CPU/footprint comparison unless applied symmetrically and explicitly reported. Add XCTest memory baselines for stable scenario workloads after on-device qualification [A3]. This suite should make regressions visible in CI, not institutionalize Linux microbenchmark numbers as macOS release thresholds.

## 10. Reproduce and integrate

The patch applies to the two verified production files and adds instrumentation, tests, the benchmark directory, and this document. It was checked against the exact selected baseline contents; a full repository build is still necessary. Apply it on a separate local branch after checking for concurrent edits:

```sh
git status --short
git apply --check /path/to/illiquid-nondecoding.patch
git apply /path/to/illiquid-nondecoding.patch
```

Portable tests and timing (Python 3.10+, Swift 6 toolchain; no application launch or network download):

```sh
python3 Benchmarks/NonDecodePerformance/run.py \
  --tests-only --output /tmp/illiquid-nondecode-tests

python3 Benchmarks/NonDecodePerformance/run.py \
  --repeats 7 --output /tmp/illiquid-nondecode-timing

# Linux/glibc only; use Instruments for macOS allocation/footprint measurement.
python3 Benchmarks/NonDecodePerformance/run.py \
  --repeats 7 --allocations --output /tmp/illiquid-nondecode-allocation
```

Each output directory must be new or empty; existing evidence is not overwritten. The driver validates original blob identities, builds isolated executables, runs the differential checks, and saves every result and command before producing summaries. It does not invoke the repository's full SwiftPM targets. On macOS its cache harness still uses the labeled doubles; run real framework tests separately:

```sh
swift test -c release --filter NonDecodePerformanceTests
swift test -c release --filter NativeThumbnailCacheTests
# Also run the repository's complete app/core/native/scheduler qualification.
```

For a dedicated benchmark bundle with the correct identity, launch its binary with these environment variables for a diagnostic Instruments capture:

```sh
ILLIQUID_ENABLE_BENCHMARK_OVERRIDES=1 \
ILLIQUID_BENCHMARK_NONDECODE=1 \
  /path/to/benchmark/Illiquid.app/Contents/MacOS/Illiquid
```

Review the three production files independently. The ranking change is the strongest measured candidate. Cache formatting/admission/pressure changes are small, separable reviews; the instrumentation branch and native test suite require macOS compilation. Do not label the combined patch release-qualified until those gates and an app-level non-regression pass are complete.

## References and evidence

Repository code references are relative to the pinned commit listed at the top, not mutable `main`:

- `Sources/IlliquidCore/Player/ThumbnailPolicy.swift`: `ranked`, `Candidate.init`, bounded exclusions.
- `Sources/IlliquidApp/App/ThumbnailBackgroundScheduler.swift`: detached ranking, bounded candidate inputs, persistent pass fairness.
- `Sources/IlliquidNativePlayback/Media/NativeThumbnailCache.swift`: key generation, admission, residency and pressure.
- `Sources/IlliquidNativePlayback/Media/NativeThumbnailDiskCache.swift`: `loadDisk`, `image`, promotion, encoding and eviction.
- `Sources/IlliquidCore/Player/PlaybackViewStore.swift`: changed-field publication.
- `Sources/IlliquidCore/Persistence/PlaybackPersistenceStore.swift` and `CoalescingPersistenceWriter.swift`: snapshots and durable background writes.
- `Sources/IlliquidCore/Playlist/ExternalSubtitleMatcher.swift` and `Sources/IlliquidCore/MediaLibrary/MediaNameRecognition.swift`: existing indexing and compiled regexes.
- `Documentation/LIFECYCLE_PERFORMANCE.md` and inspected opening sections of `Documentation/PERFORMANCE_FOLLOWUP.md`: prior work, not new measurements from this investigation.

Primary documentation:

[A1] Apple, [OSSignposter](https://developer.apple.com/documentation/os/ossignposter).
[A2] Apple, [Improving app responsiveness](https://developer.apple.com/documentation/xcode/improving-app-responsiveness).
[A3] Apple, [Preventing memory-use regressions](https://developer.apple.com/documentation/xcode/preventing-memory-use-regressions).
[A4] Apple, [Understanding and improving SwiftUI performance](https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance).
[A5] Apple, [Reducing disk writes](https://developer.apple.com/documentation/xcode/reducing-disk-writes).

New measured evidence: `Benchmarks/NonDecodePerformance/evidence/summary.json`, `measurements.jsonl`, `tests.json`, both cache traces, source manifests, execution notes and command logs. Raw evidence, not rounded table values, is authoritative.
