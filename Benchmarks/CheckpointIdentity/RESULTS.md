# Checkpoint identity research: exploratory results

## Disposition

The Linux experiment passed its behavior checks but **did not meet the declared
performance acceptance criteria**. It is retained as exploratory research.
No separate implementation PR was opened from this research because concurrent
[PR #124, "perf: avoid redundant playlist scans in playback checkpoints"](https://github.com/Jagalite/illiquid/pull/124)
covers the same optimization. The overlap audit also found the
`perf/checkpoint-membership-20261028`,
`perf/playback-checkpoint-membership-20261028`, and
`codex/perf-checkpoint-construction` branches. The measurements below belong
solely to this Linux study.

The native workflow for this branch,
[run 40634898603](https://github.com/Jagalite/illiquid/actions/runs/40634898603),
was last observed **queued at 2026-10-28 05:17 UTC**. That is a pending execution
status, not a native test or benchmark result. No native performance or
whole-player improvement is established by this report.

## Change and measurement boundary

`PlaybackCheckpoint.record()` previously normalized the source URL again for
each visited playlist item while deciding whether to retain the collection
folder. It also performed that membership check when the checkpoint's folder
was nil, even though the resulting collection folder would necessarily be nil.

The candidate skips membership work for folderless checkpoints and reuses one
source identity within a folder-backed scan. Source identity is resolved only
after the first valid item, preserving the empty/all-unsupported input path.
It retains the original URL admission rules, playlist scan order, supplied
folder, saved index, item metadata, and record constructor. There is no
index-based shortcut or persistent cache.

The benchmark measures the **complete production `record()` call**, including
the unchanged session-record construction, deduplication, and result-lifetime
work in the timed loop. Its inexpensive checksum consumes each result. JSON
encoding, disk writes, and queue scheduling are outside that interval.

The source baseline is `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`.
The candidate was measured as uncommitted work on that baseline, so the
manifest's `candidate_head` alone does not identify its changed bytes. The
recorded production SHA-256 values for `PlaybackCheckpointWriter.swift` are:

| Arm | Source SHA-256 |
| --- | --- |
| Baseline | `72e1b32e382d18736c54ae2222b91c7093bb0c9577c8197c630e74fd8405d591` |
| Candidate | `ebdfeab9e8992209d8587889fd9832f92430d33c6e3cdcd71b42c61bf5bfccf9` |

The [manifest](evidence/linux-exploratory/manifest.json) records the shared
support-file, driver, test, and executable hashes. Only the checkpoint file
differs among the compiled production sources. On Linux, both arms use the
same disabled `LifecyclePerformance` diagnostic flag in place of its macOS
signposting implementation; the measured record and identity code is unchanged.

## Experiment and behavior checks

The run used Swift 6.3.2 on x86_64 Linux 6.18.55 with glibc 2.39. It was the
`--quick` configuration: **24 workloads, four baseline/candidate pairs per
workload, and 192 final timed observations**. Calibration targeted 40 ms per
batch. Each pair used the same iteration count, alternating AB/BA order in
fresh serial processes. Fixture creation was outside timing. Production code
and the driver were compiled as separate optimized modules.

The quick matrix covers 0, 1, 32, and 1,000 items, with folder first/last/missing
matches, folderless last/missing matches, and remote sources. It does not
include the full study's 10,000-item cases or additional middle/early-hit
folderless workloads. Counts, sample order, and iteration counts are retained
in [workloads.json](evidence/linux-exploratory/workloads.json),
[calibration.json](evidence/linux-exploratory/calibration.json), and
[measurements.jsonl](evidence/linux-exploratory/measurements.jsonl).

All **58 tests in nine suites passed in each of four configurations**:

| Arm | Configuration | Result |
| --- | --- | --- |
| Baseline | Debug | 58 tests passed |
| Baseline | Release | 58 tests passed |
| Candidate | Debug | 58 tests passed |
| Candidate | Release | 58 tests passed |

These are the same 58 tests run four times, not 232 distinct tests. The suites
include complete checkpoint-record comparisons against the historical logic,
URL and authority validation, Unicode and relative aliases, duplicate metadata,
saved-index independence, position sanitization, timestamps, and existing
playlist/session behavior. The original logs are preserved in
[logs.json.gz](evidence/linux-exploratory/logs.json.gz); the execution receipt is
[tests.json](evidence/linux-exploratory/tests.json).

All **24 workload fixtures** produced byte-identical complete sorted-key record
JSON between arms after replacing only the clock-derived `updatedAt` field
with the same fixed value. Verification checks the original timestamp's bounds
and JSON round trips. Every final timed result was also compared with its
workload's complete reference bytes; all **192 observations** reported valid
timestamp bounds and passed their paired checksums. See
[verification.json](evidence/linux-exploratory/verification.json) and the retained
complete records in [semantics.json.gz](evidence/linux-exploratory/semantics.json.gz).

## All 1,000-item primary results

The following values were independently recomputed from
`measurements.jsonl`. Each observation is divided by its recorded iteration
count before taking the median for an arm. Reduction is
`100 * (1 - candidate_median / baseline_median)`; a negative value means slower.
The final column counts pairs in which the candidate was faster. Each row has
four pairs.

| Workload | Metric | Baseline median per record | Candidate median per record | Reduction | Faster pairs |
| --- | --- | ---: | ---: | ---: | ---: |
| Folder, last item | Wall | 36.061 ms | 41.215 ms | **-14.29%** | 1/4 |
| Folder, last item | Process CPU | 29.438 ms | 24.137 ms | 18.01% | 3/4 |
| Folder, missing item | Wall | 57.250 ms | 52.129 ms | 8.94% | 2/4 |
| Folder, missing item | Process CPU | 33.387 ms | 24.039 ms | 28.00% | 3/4 |
| No folder, last item | Wall | 44.910 ms | 24.862 ms | 44.64% | 4/4 |
| No folder, last item | Process CPU | 34.564 ms | 12.223 ms | 64.64% | 4/4 |
| No folder, missing item | Wall | 77.286 ms | 24.896 ms | 67.79% | 3/4 |
| No folder, missing item | Process CPU | 32.526 ms | 12.936 ms | 60.23% | 4/4 |

The folderless cases show a clearer component benefit in this run. The
folder-backed results do not establish success: the last-item wall median
regressed, and the missing-item wall reduction was below the 15% target.
The CPU improvements do not override those failed wall-time criteria.

The ratio of arm medians and the median of paired ratios are different
statistics. For folder-backed last/missing cases, the paired median wall-time
reductions were **-35.24% and -12.35%**, respectively. This disagreement with
the arm-median ratios reinforces the uncertainty in the short run. Both
statistics and all observations are retained in
[summary.json](evidence/linux-exploratory/summary.json).

The large cases used only two or three calls in each timed batch. For example,
the folder-last 1,000-item batch wall times ranged from approximately 63 to
249 ms across arms. Process CPU time varied too; scheduling delay alone is
not established as the cause. The exploratory measurements must not be
presented as stable native latency estimates.

## Failed gates and controls

The predeclared full acceptance criteria require native macOS qualification,
at least eight pairs, at least 15% median wall and CPU improvement for every
1,000- and 10,000-item primary case, improvement in at least seven of eight
pairs, and no repeatable control slowdown above 10%. See the
[method and reproduction instructions](README.md).

This Linux quick cohort is ineligible for that qualification. Its own
implemented primary median and pair-consistency checks also failed. The
[acceptance receipt](evidence/linux-exploratory/acceptance.json) records:

- `accepted: false`
- `qualifying_cohort: false`
- `primary_medians_pass: false`
- `primary_pair_consistency_pass: false`

It also flags the following seven control metric/workload combinations for
more than 10% median slowdown. These observations were retained; this report
does not classify them as harmless noise or resolved regressions.

| Control | Metric | Candidate median slowdown |
| --- | --- | ---: |
| Folder, last, 0 items | Process CPU | 14.85% |
| Folder, first, 1 item | Wall | 22.23% |
| Folder, first, 1 item | Process CPU | 21.38% |
| Folder, last, 1 item | Process CPU | 18.65% |
| Folder, missing, 1 item | Wall | 14.02% |
| Remote source, 32 items | Process CPU | 12.46% |
| Folder, first, 1,000 items | Wall | 12.92% |

## Practical relevance and limits

`PlaybackController` requests progress saving when the absolute change from
the last checkpointed media position reaches ten seconds. That is roughly
once per ten wall-clock seconds during steady 1x playback, not a fixed
wall-clock timer; seeks, speed changes, pause events, and explicit lifecycle or
playlist actions affect requests. Accepted checkpoints are coalesced, and
record construction runs on the utility writer queue.

Reducing repeated normalization can reduce background checkpoint-construction
CPU, particularly for a late playlist member or a playlist without a folder.
The remaining record deduplication is still linear for multi-item playlists.
The benchmark does not measure main-actor shuffle restoration, encoding,
atomic I/O, queue delays, or complete shutdown/flush latency. It also provides
no playback FPS, live UI, battery, process-memory, or whole-player CPU result.
Checkpoint cadence, stored data, and durability behavior are unchanged by the
candidate.

The retained evidence consists of eleven files under
[evidence/linux-exploratory](evidence/linux-exploratory/), including the exact
[command log](evidence/linux-exploratory/commands.jsonl), manifests, complete
semantic outputs, test logs, calibration, every final observation, summary, and
acceptance receipt. No additional test or benchmark run was performed while
preparing this report.
