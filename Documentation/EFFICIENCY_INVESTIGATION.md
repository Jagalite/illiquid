# Playback efficiency investigation — 2026-10-07

## Scope and evidence

This investigation covers the eight follow-ups from the playback review. Work ran at niceness 15, with one Swift build job and serial tests, while other testing continued. The source snapshot was copied into `QualificationArtifacts/EfficiencyInvestigation/workspace`; its 449 input hashes are in `baseline-inputs.json`. The checkout was already heavily modified, so the snapshot is not equivalent to its HEAD commit (`2e6d3ad4dbeeaa1e6e20940ff5fbbb4c549d6e57`). No installed application was replaced.

Swift component probes use a debug build and the pinned FFmpeg 8.1.2-illiquid1 pkg-config directory. Headless renderer observations cannot establish displayed-frame smoothness, physical output correctness, whole-app energy, or release-build parity with mpv/IINA. Historical receipts remain historical; this report does not convert them into current qualification.

## Large-library work

`SourceMediaPresenceScanner.setRoots` compared every source against every other source to remove descendants, then repeated overlap searches while building the initial job queue. The change uses a set and checks each path's ancestors, preserving sorted, disjoint roots. The initial/rescan queues can then be populated directly. Incremental repair overlap logic is preserved.

An optimized standalone probe compiled the actual helper and asserted equivalence with the old algorithm. Three alternating samples per size on this shared host gave these medians:

| Independent roots | Original pruning | Updated pruning |
|---|---:|---:|
| 1,000 | 87.14 ms | 0.82 ms |
| 5,000 | 2,451.82 ms | 4.51 ms |
| 10,000 | 11,750.34 ms | 9.55 ms |

This measures root pruning, not overall startup, traversal, SwiftUI publication, or the previously observed 114 ms main-queue hitch. It removes one demonstrated scaling problem without claiming the broader hitch is resolved.

## Qualification policy

The performance suite previously accepted equal nonzero dropped-frame counts as nonregression. It now reports relative regression and absolute dropped-frame quality separately, and requires both for its overall pass. A zero-drop candidate compared with a dropping baseline is still identified as a relative improvement, but the pair is not a clean playback qualification. Reanalyzing the old alternating suite produced four failed absolute checks out of nine. This is stricter interpretation of existing evidence, not a fresh playback measurement.

## Interrupted reads

Fault injection reproduced unbounded interrupted-read retries in the main demux, fair-dispatch, and delayed-audio loops: 87,357, 54,405, and 85,551 calls respectively during approximately 150 ms observation windows. These are injected call counts, not a real-media CPU benchmark. INVALIDDATA from a superseded read also incorrectly failed the new seek; errors returned during stop were reported as playback failures. The reproduction produced 12 failed assertions across these behaviors.

The change checks stop/disable and synchronizes with seek publication before deciding whether a read was superseded. Only a newer generation justifies retry; a terminal failure is reported once. Existing bounded retries inside the input layer remain unchanged. Test seams default to nil, preserving the real input path.

Two existing test helpers needed compatibility changes for this SDK: the nested Observable helper cannot be private, and the thread assertion must be made from a synchronous helper. Neither changes application behavior. Concurrent work independently made identical changes in the shared checkout; this investigation did not overwrite them.

## Cold previews and cache identity

The headless playback probe ran four seconds steady and four seconds with four cold preview requests. HEVC 10-bit 1080p60 used 5.14% then 36.68% of one core; VP9 1080p60 used 16.34% then 37.63%. All eight previews completed. Both renderer clocks advanced and reported zero starvation deltas and no renderer failure. There was no visible window, so these observations do **not** qualify displayed-frame drops. Fixture order and allocator reuse also prevent comparing the codecs' absolute footprints as independent samples.

Separate seven-request thumbnail batches compared two threads with one. Every returned image hash matched across configurations:

| Fixture | Two threads: wall / CPU work | One thread: wall / CPU work |
|---|---:|---:|
| H.264 4K | 585 / 953 ms | 1,435 / 934 ms |
| HEVC 1080p60 | 553 / 952 ms | 1,056 / 999 ms |
| VP9 1080p60 | 378 / 527 ms | 537 / 502 ms |

These are single batches per configuration on a shared host; the batch includes cache hits. Lower thread count does not convincingly reduce work and worsens latency here, so the default remains two. Cold preview decoding remains a high-priority efficiency target. Its next evaluation should compare bounded preview work during visible playback, including image correctness and request completion, rather than optimizing CPU alone.

Fifty local cache observations gave median 0.0017 ms direct RAM lookup and 0.0330 ms identity-plus-RAM lookup. Removing an owned temporary source left its image resident but prevented resolving its key. Local stat overhead is small in this sample; unavailable or slow mounted storage remains an availability problem. Bypassing identity verification would weaken replacement-file protection. A future solution needs explicit session-bound identity and invalidation semantics, including unavailable-source behavior. No cache policy was changed.

## Subtitle locking and repeated inputs

Forty authored simultaneous animated ASS cues at 1920x1080 produced 68 main-actor event-count observations: median 0.00013 ms, p95 1.16 ms, maximum **20.48 ms**. This directly exercises the pipeline lock shared by libass rendering and main-actor queries. It demonstrates blocking potential under an artificial stress case, not frequency in ordinary subtitles or measured dropped frames.

Simply releasing the lock around libass would race configuration, cue ingestion, seek, track replacement, and shutdown. The next implementation should give rendering/context mutation one serial owner while publishing immutable state and accepting main-actor requests without waiting for a render. Revision fences and PiP behavior must remain intact. No speculative lock split was promoted.

Twelve construction/release cycles alternated AV only, embedded subtitles, and subtitles plus 100 ms audio delay. Median construction times were **16.14 / 31.07 / 44.05 ms**. This includes subtitle-pipeline setup and independent demuxer initialization, and does not start playback. Post-release process footprint warmed from 32.08 to about 37.11 MiB and flattened in later cycles. It neither proves nor disproves the historical hover/resize memory regression.

Startup source remains sequential for history and source-settings reads on a detached task. The existing 100,000-item source-snapshot test completed its worker load in 0.593 s and verified it was off the main thread. This is not application launch time. No startup ordering change was justified by this run.

## Decoder routes and seeking

Three alternating software/hardware repetitions per codec decoded at least 60 output frames per phase. Actual routes were asserted. VP9 supplemental registration occurred only in this isolated probe process.

| VP9 phase | Software: first frame / CPU work | Hardware: first frame / CPU work |
|---|---:|---:|
| Initial | 6.76 / 112.76 ms | 6.31 / 10.83 ms |
| Seek 8.5 s | 238.40 / 349.56 ms | 387.03 / 28.39 ms |
| Backward seek 2 s | 209.40 / 321.00 ms | 386.89 / 26.00 ms |

Hardware VP9 greatly reduces CPU work but worsens seek latency in these fixtures. Keep it opt-in. These decoder observations exclude rendering and do not measure system/GPU energy. HEVC hardware also reduced CPU work and was faster than software in these component phases; its existing preference remains intact.

The current runtime completed all twelve exact-seek probes, with command-to-observed-preroll ranges of **152–423 ms H.264 4K**, **29–132 ms HEVC**, and **186–280 ms VP9**. Targets were 1.5, 8.5, 18.5, then 2 seconds. These are one sample per target, not latency distributions or physical-output timings. The existing software seek burst appeared in the long-GOP H.264 run; no burst/prebuffer policy was changed.

Hardware output equivalence passed on four fixtures (H.264, HEVC 10-bit, VP9, VP9 10-bit), comparing decoded pixels, timing, and metadata before/after seek. That adds bounded correctness evidence, not full output qualification.

## Preview memory lifetime

Eight H.264 4K cycles each created a generator, decoded three previews, requested idle release, applied critical cache pressure, then released the owner. Process footprint started at **13.28 MiB**, reached **140.85 MiB** after the first decode batch, and remained **139.88–140.72 MiB** after owner release across the cycles. From cycle 1 to cycle 7, post-release footprint rose only about 0.20 MiB. This suggests a large warm-up plateau in this bounded observation, not evidence of an unbounded leak.

The idle-release API schedules worker cleanup rather than providing a synchronous drain barrier. Immediate post-request values therefore cannot prove decoder release; the owner-release observations include a 100 ms delay but are not an ownership proof either. Process footprint also includes allocator/framework/static Core Image caches. The next useful investigation is allocation/ownership tracing across decoder cleanup and renderer resizing, separating live resources from reusable allocator pages. No aggressive cache purge or renderer-pool change was made without that evidence. Historical whole-app hover and resize regressions remain open.

## Validation and remaining work

- Focused candidate run: **50 tests in nine suites passed**. Two opt-in real-media subtitle tests were skipped in that run.
- Performance harness: **12 Python tests passed**, including equal nonzero drops and improvement from a dropping baseline.
- Serial component runner: **15 invocations succeeded**, with fixture hashes, host load, logs, and receipts in `QualificationArtifacts/EfficiencyInvestigation/probes`.
- Additional run: **three tests passed**—repeated preview-memory lifecycle plus both optional real-media subtitle tests, using the authored animated-ASS fixture. Those subtitle seeks include positions beyond this short fixture; they do not substitute for long-form media coverage.
- Architecture checks passed.
- No full state-space suite, release archive, installed-app run, visible desktop comparison, or physical energy measurement was performed.

The remaining product priorities are visible 60 fps playback qualification, cold-preview contention, subtitle main-thread blocking, and hover/resize memory lifetime. A controlled visible comparison against the same mpv/IINA fixtures remains necessary before claiming performance parity. This investigation intentionally makes no such claim.

## Reproduction and artifacts

The isolated workspace uses `/tmp/illiquid-efficiency-build-20261007` as its scratch build. Build with `PKG_CONFIG_PATH=/opt/homebrew/Cellar/ffmpeg/8.1.2-illiquid1/lib/pkgconfig`, `nice -n 15`, and `swift test --jobs 1 --no-parallel`. The opt-in `EfficiencyInvestigationTests` require `ILLIQUID_EFFICIENCY_OUTPUT`; individual methods also require `ILLIQUID_EFFICIENCY_CODEC_FIXTURES`, `ILLIQUID_EFFICIENCY_SUBTITLE_FIXTURE`, or `ILLIQUID_EFFICIENCY_MEMORY_FIXTURE` as applicable. The probe runner records its exact selections and environment.

Artifacts are under `QualificationArtifacts/EfficiencyInvestigation/`:

- `baseline-inputs.json`: source snapshot hashes; `promoted-files.json` and `changes.patch`: reviewed promotion scope.
- `reproduction-run.log`: original read-loop failures; `focused-tests.log`: candidate checks.
- `root-benchmark.swift`, `root-benchmark.json`: optimized algorithm comparison and raw samples.
- `historical-gates-reanalysis.json`: reinterpretation of historical receipts only.
- `run-probes.py`, `probes/runs.json`, `probes/fixtures.json`: serial runner, load/niceness, exact fixture hashes.
- `probes/*.json` and logs: component results; `memory-and-subtitle-tests.log`: final additional run.
- `architecture-check.log`, `harness-tests.log`: structural and harness checks.

Earlier build logs record the test-helper compiler failures and an interrupted first build on the external volume. They are not passing validation receipts. The current workspace contains other concurrent work; passing isolated checks applies to the hashed snapshot plus these changes, not arbitrary later edits.


## Progressive current-video previews — 2026-10-07

Implemented the broad-coverage / approximate-display / local-refinement approach reviewed in Demuxe. This is an independent native implementation; it does not import Demuxe or change playback decoder defaults.

- `ThumbnailPreferences.preparesCurrentVideo` defaults to true, including decoding older settings without the new field. A separate settings toggle disables it. Library-wide idle preparation retains its existing opt-in setting.
- The current video receives up to 24 progressively distributed storyboard positions, followed by five-second samples within 30 seconds of the focus. Hover interest expires after 1.5 seconds during playback, allowing the working area to follow playback again. Paused hover interest persists.
- The scheduler waits the configured idle delay (default three seconds), uses the existing pass work budget (default fifteen seconds), and leaves **two seconds between requests**. Completed broad positions survive pass budgets; failed attempts have a bounded twenty-second cooldown. Attempt bookkeeping and broad tracking are bounded.
- Current-video work is admitted only in playing or paused states. Loading, seeking, buffering, hidden-window policy, memory pressure, Low Power Mode, and serious/critical thermal state stop or defer work. The player checks its runtime phase before decoding; the existing worker suspension, foreground priority, and source-revision fences remain authoritative.
- Hover uses the nearest prepared image across the timeline, with its actual represented timestamp and the existing approximate indicator. Deterministic storyboard positions enable disk lookup after restart; source identity and dimensions must match. Exact refinement waits 180 ms for the pointer to settle.
- Background local images cannot evict the current storyboard. Foreground demand and memory pressure still take precedence. Storyboard protection moves to a new source identity, rather than accumulating permanent protection for previously opened videos. Default and balanced RAM budgets now match Demuxe at 16 MiB, with a 96-image resident cap; the existing 256 MiB default disk cache remains. Explicit saved RAM budgets are preserved.

### Measurements and validation

Review fixes: metadata and decode completions recheck scheduler generation before updating coverage, so cancelled work cannot mark a replacement source prepared. Background admission now uses the same unprotected eviction candidates as memory trimming, including the 96-entry cap. Automatic local-video preparation ignores remote URLs, and cancelled cache hits cannot change storyboard protection. The source-switch and protected-cap regression cases plus existing priority/admission checks passed: 50 tests across seven suites (`review-fixes-final.log`, `review-fixes-hashes.json`). No new real-media performance measurements were run for these correctness fixes.

Demuxe adaptive-default alignment passed 43 focused tests across five suites, including eviction at 96 resident images below the byte budget and an off-grid focus remaining within the 30-second radius. See `adaptive-defaults-final.log` and `adaptive-defaults-hashes.json`; this follow-up did not repeat real-media performance measurements.

The initial 500 ms spacing was too costly on native software preview decoding: one six-second HEVC preparation observation used 61.7% of one core, versus 6.1% steady playback; VP9 used 42.3%, versus 16.5%. This motivated the two-second spacing rather than copying Demuxe's cadence directly.

With two-second spacing, single debug headless observations on this shared host prepared three images during each six-second observation and served a cached approximation:

| Fixture | Steady CPU, one core | During preparation | Resident preview bytes |
|---|---:|---:|---:|
| HEVC 10-bit 1080p60 | 7.2% | 34.4% | 914,112 |
| VP9 1080p60 | 17.4% | 25.9% | 914,112 |
| H.264 4K | 7.2% | 18.7% | 914,112 |

These are process CPU observations, not system energy or displayed-frame measurements. They show the cost of preparation and the coverage/pacing tradeoff; they do not prove no playback regression. The first open still needs time to create coverage. Full broad coverage takes tens of seconds or longer depending on decode cost, pass pauses, and resource constraints. Persisted images can provide coverage immediately on later opens.

Focused validation results and the final source hashes are in `QualificationArtifacts/ProgressivePreviews/`. The tests exercise source replacement, disk fallback, memory pressure, storyboard eviction, automatic preparation during stable playback, interruption for recovery, and repeated hover without starvation. Optional real-media checks use a headless surface and isolated history/cache directories.

The installed application was not replaced. Visible hover UX, 60 fps displayed drops during preparation, system energy, and full memory reclamation remain unqualified.

Final source checks: **47 focused tests in seven suites passed**, including real VP9 playback and shared-cache delivery. Architecture checks passed. Final HEVC and VP9 queries requested approximately 8.9 seconds and received the prepared six-second image in **1.64 and 1.67 ms**, respectively. These are cache API timings, not pointer-to-screen timings. Three images were resident in each observation.

The final-source CPU observations varied: HEVC was 6.3% steady / 30.4% preparing, and VP9 was 27.9% / 30.2%. Together with the earlier samples, this reinforces the shared-host and short-window limits; no current-build CPU nonregression or system-energy qualification is claimed.

A broader combined snapshot run executed 105 tests in twelve suites and failed four assertions in `completedPressesDistinguishDoubleClickAndCancelDrags`, after concurrent double-click interaction changes. Preview suites passed in that run. The click implementation and test were preserved as concurrent work; this feature does not claim the broader suite passed.

Artifacts: `focused-final.log`, `combined-validation.log`, `architecture-final-source.log`, individual media receipts, fixture hashes, and final source hashes under `QualificationArtifacts/ProgressivePreviews/`. `source-changes.patch` contains this feature's source changes; `changed-files.json` includes source and test hashes. Initial failed logs retain the previous hover-delay expectation, library-only fixture expectations, and the initial headless-surface setup error. None is treated as passing evidence.
