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
