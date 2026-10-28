# Zero-index checkpoint hint: focused performance qualification

This study compares #140 at `2620d561d11c9a7d9396d3b455424a10a6dddcd7` with the same implementation plus an `index > 0` guard. The production and measurement sources were committed together at `e9fbb2e7c1e36df80fdde1cef66aebea66fdc463` before results were available.

The verified positive-index shortcut and source-key reuse belong to #140/#124. This report makes no claim to those improvements. The new guard skips a redundant normalization when the hint is zero and the source does not match that first item. The fallback already checks item zero first.

## Decision

The extra guard produced a clear component-level reduction in the small zero-hint miss cases. The missing singleton used **33.87% less process CPU time** by the median paired ratio; the two-item stale-zero and missing-zero cases used **16.67%** and **16.60%** less. Every pair was faster in those three workloads. Separate absolute medians were 14.610 → 9.608 µs, 30.745 → 25.552 µs, and 30.279 → 24.938 µs per complete record respectively.

This supports a narrow draft follow-up to #140. The one-item matching control was +0.016% by the paired median, with four of eight pairs faster. Across all 17 controls the median changes ranged from −0.56% to +1.53%; the largest was the 32-item matching-last control, where six of eight candidate samples were slower. Every control's full paired range included both signs. These observations do **not** prove an absence of regression. They provide no strong evidence of a broad cost, but native validation remains necessary.

The eight-item affected cases had smaller reductions (4.57–5.65% median), and the 32-item effects (1.27–2.30%) were small relative to the observed variability. Single pairs can be noisy: even an unaffected remote-source control ranged from −16.03% to +28.64%. The report retains every observation and does not promote the small effects to a statistical-significance claim.

## Reachable player state

Removing the currently playing first item from a two-item folder playlist first updates the playlist to the remaining singleton and sets the index to zero. The replacement load then calls saveCurrentProgress() while the current source still identifies the removed media. With history enabled and a valid current session, checkpointSession() can therefore enqueue exactly the missing-source/zero-index state studied here. See [playlist removal](https://github.com/Jagalite/illiquid/blob/e9fbb2e7c1e36df80fdde1cef66aebea66fdc463/Sources/IlliquidPlayer/Player/PlaybackController.swift#L1375-L1403), [progress saving before replacement load](https://github.com/Jagalite/illiquid/blob/e9fbb2e7c1e36df80fdde1cef66aebea66fdc463/Sources/IlliquidPlayer/Player/PlaybackController.swift#L1516-L1528), and [checkpoint capture and authority check](https://github.com/Jagalite/illiquid/blob/e9fbb2e7c1e36df80fdde1cef66aebea66fdc463/Sources/IlliquidPlayer/Player/PlaybackController.swift#L1922-L1953).

This is a source-level reachability argument, not a measured user interaction. The coalescing writer may replace such a checkpoint before record construction. Its execution frequency and player-level impact remain unmeasured. Ordinary steady playback generally has a matching hint, which is why matching hints are controls.

## Protocol and reproducibility

24 workloads, eight balanced AB/BA fresh-process pairs per workload, 384 timed observations. Baseline calibration targeted 250 ms process CPU per sample with a common iteration count across each baseline/candidate workload. Each process performed four excluded warmup calls. Every sample was retained. The primary percentage is the median of within-pair candidate/baseline CPU ratios; absolute times are separate medians per call.

The complete production record method runs behind a separate module and non-inline wrapper. Timings include record initialization, existing playlist deduplication, Date(), minimal checksum consumption and release. Fixture construction, independent expected records, JSON encoding and full-output comparisons are outside the interval.

Both variants run existing regression tests in debug and release. The independent differential driver compares 1,158 complete normalized records against the original existential membership rule, then compares exact encoded records across both variants, normalizing only updatedAt. Every timed sample checks full record equality before/after and its checksum.

## Provenance

- Successful measurement run: [40641117684](https://github.com/Jagalite/illiquid/actions/runs/40641117684), job [122659256325](https://github.com/Jagalite/illiquid/actions/runs/40641117684/job/122659256325).
- Execution: **2026-10-28, 06:03:51–06:06:10 UTC**. Both source variants were built on the same runner, serially.
- Baseline: `2620d561d11c9a7d9396d3b455424a10a6dddcd7`, the unmodified #140 implementation.
- Measured candidate: `e9fbb2e7c1e36df80fdde1cef66aebea66fdc463`; the checkout was clean.
- Compiler: **Swift 6.3.2**, target **x86_64-unknown-linux-gnu**.
- Host CPU reported **AMD EPYC 9V45 96-Core Processor**; the hosted runner/container does not imply exclusive access to all host cores.
- OS/container: **Ubuntu 24.04.4**, official image `swift:6.3.2-noble@sha256:c4336909a71b2e69b884f4078cdf98c0cd081911632cb349ef72abc4cbed69fc`.
- Hashing: `SWIFT_DETERMINISTIC_HASHING=1`; release builds used warnings-as-errors and testability so the driver can call the existing internal checkpoint API.
- All four baseline/candidate debug/release test commands succeeded. Existing checkpoint XCTest and core Swift Testing suites were reused without edits; the Linux atomic-store suite was intentionally excluded.
- All **1,158** full differential records matched. Baseline and candidate verification output SHA256 were identical: `b52cea5b11db7a6be9da54e95e25997adad4bf45593003e9051e1d767ba53753`.
- The **384** measurements form exactly 24 workloads × eight pairs × two variants. Each pair has common iterations, balanced order and matching output receipts. Independent arithmetic checks reproduced the CPU and wall summaries. All 456 recorded commands exited successfully.
- Baseline timed CPU samples ranged from **200.47 to 293.29 ms**; candidate samples ranged from **137.61 to 313.87 ms**. The 250 ms setting is a baseline calibration target, not a guaranteed per-sample duration.
- Source hashes for the parent and candidate checkpoint, the unchanged parent regression suite, the driver and runner were recomputed against the committed text and matched the manifest. All nine shared full Core source hashes match across variants; seven Core files are compiled in portable mode, including the exact record/protocol prefix of the session-store file.
- Native macOS run [40641117665](https://github.com/Jagalite/illiquid/actions/runs/40641117665) was still queued when these Linux results were recorded. No native or full-player result is claimed.

### Retained receipts

The permanent [Linux evidence directory](evidence/linux/) contains [summary.json](evidence/linux/summary.json), [manifest.json](evidence/linux/manifest.json), [all observations](evidence/linux/observations.jsonl), [calibration observations](evidence/linux/calibration.json) and [command receipts](evidence/linux/commands.jsonl). These are extracted verbatim from the successful workflow's marked receipts, with only the external timestamp prefixes and surrounding blank space removed. Complete command/test logs and the runner snapshot are also in that run's artifact (14-day retention). The runner and driver remain committed at the measured revision.

The later report/evidence commit does not change the measured production source, driver, runner, or tests. It removes the temporary push triggers from the two new workflows; pull requests retain correctness qualification, and the native/manual workflows can reproduce measurements.

## Complete results

Absolute times below are separate per-variant medians per complete record. Percentages are medians of within-pair ratios, so they need not equal the ratio of the displayed medians. Negative means less time. The ranges contain all eight paired changes, not confidence intervals.

### Affected zero-hint cases

| Workload | Items | Baseline µs | Candidate µs | Paired CPU change | Faster pairs | Full paired CPU range | Paired wall change |
|---|---:|---:|---:|---:|---:|---|---:|
| Missing source, hint 0 | 1 | 14.610 | 9.608 | -33.87% | 8/8 | -39.01% to -29.04% | -33.87% |
| Last-item match, stale hint 0 | 2 | 30.745 | 25.552 | -16.67% | 8/8 | -19.89% to -9.46% | -16.67% |
| Missing source, hint 0 | 2 | 30.279 | 24.938 | -16.60% | 8/8 | -22.26% to -10.53% | -16.60% |
| Last-item match, stale hint 0 | 8 | 92.192 | 86.308 | -5.65% | 7/8 | -8.37% to +4.15% | -5.64% |
| Missing source, hint 0 | 8 | 91.648 | 86.086 | -4.57% | 8/8 | -7.35% to -2.56% | -4.58% |
| Last-item match, stale hint 0 | 32 | 340.539 | 336.341 | -2.30% | 6/8 | -3.07% to +5.19% | -2.30% |
| Missing source, hint 0 | 32 | 342.449 | 340.541 | -1.27% | 6/8 | -7.55% to +13.09% | -1.27% |

### Unaffected controls

| Workload | Items | Baseline µs | Candidate µs | Paired CPU change | Faster pairs | Full paired CPU range | Paired wall change |
|---|---:|---:|---:|---:|---:|---|---:|
| Matching first-item hint | 1 | 10.266 | 10.209 | +0.02% | 4/8 | -7.36% to +6.40% | +0.00% |
| Matching first-item hint | 2 | 20.727 | 20.704 | -0.56% | 4/8 | -7.44% to +8.67% | -0.56% |
| Matching last-item hint | 2 | 20.621 | 20.634 | -0.03% | 4/8 | -3.49% to +6.36% | -0.03% |
| Matching first-item hint | 8 | 51.587 | 51.812 | -0.35% | 6/8 | -4.06% to +6.46% | -0.36% |
| Matching first-item hint | 32 | 178.792 | 177.907 | -0.13% | 4/8 | -4.21% to +1.05% | -0.12% |
| Matching middle-item hint | 32 | 178.035 | 179.315 | +0.54% | 4/8 | -2.23% to +3.53% | +0.53% |
| Matching last-item hint | 32 | 179.504 | 182.146 | +1.53% | 2/8 | -1.13% to +7.07% | +1.55% |
| Matching last-item hint | 256 | 1361.214 | 1362.623 | -0.33% | 6/8 | -9.58% to +1.68% | -0.33% |
| Last-item match, no hint | 32 | 336.993 | 343.372 | +0.39% | 3/8 | -6.26% to +20.66% | +0.39% |
| First-item match, stale positive hint | 32 | 184.786 | 183.769 | -0.08% | 4/8 | -2.00% to +17.27% | -0.09% |
| Last-item match, out-of-range hint | 32 | 334.017 | 335.888 | +0.69% | 3/8 | -1.10% to +9.14% | +0.69% |
| Missing source, positive hint | 32 | 345.674 | 343.742 | -0.38% | 4/8 | -8.60% to +6.40% | -0.38% |
| Remote source | 32 | 171.312 | 170.989 | -0.28% | 4/8 | -16.03% to +28.64% | -0.27% |
| No collection folder | 32 | 168.816 | 169.270 | -0.07% | 5/8 | -3.79% to +2.48% | -0.07% |
| Empty playlist | 0 | 0.0717 | 0.0719 | +0.83% | 4/8 | -1.63% to +2.31% | +0.83% |
| Last-item match, no hint | 2 | 25.941 | 25.608 | -0.26% | 4/8 | -7.29% to +3.14% | -0.26% |
| Last-item match, out-of-range hint | 2 | 25.634 | 25.833 | +0.34% | 3/8 | -6.31% to +27.53% | +0.34% |

## Limits

These are Linux component measurements; they do not establish macOS Foundation performance. The macOS workflow compiles the complete native sources and remains a separate validation gate. Linux compiles the complete production checkpoint writer and exact unchanged record/protocol declarations, omitting only the unrelated platform-specific atomic-store implementation and its tests.

The benefit affects stale or missing zero-index hints. Their frequency in real sessions has not been measured. Complete checkpoint construction remains O(n) because deduplication is unchanged. The study does not measure encoding, atomic writes, queue delay, user-visible playback latency, frame rate, energy, memory footprint or whole-player CPU. A repeated warm loop without per-call autorelease pools is not a memory measurement.

The earlier main-versus-shortcut experiment was superseded by concurrent PRs #124, #140 and #168. Its performance numbers are not evidence for this incremental change.
