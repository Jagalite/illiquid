# Playback checkpoint membership follow-up research

## Final result and status

The final eager-source revision, `c98d899b5aa30c4e6c7b6c4a24c64a48a0991bac`,
meets the narrowed singleton-miss target against PR #140's pinned implementation.
Complete checkpoint construction fell from **12.196 to 8.229 microseconds** in
[the successful hosted Linux job](https://github.com/Jagalite/illiquid/actions/runs/40639121629/job/122652872786):
**32.36% less paired wall time and 32.35% less paired CPU time**, faster in all
8 retained pairs. None of the other 25 controls crossed the investigation gate.

This is a small follow-up to PR #140. It removes a repeated item-normalization
operation; the upstream indexed shortcut is already in the comparison baseline.
The PR remains a draft pending native macOS component measurements and full
application/checkpoint/coordinator qualification. Linux component success does
not establish those native results.

## Question

Can playback checkpoints avoid repeated work after an index miss while returning
the same complete session record?

`PlaybackCheckpoint.record()` runs on the coalescing persistence writer's queue.
The controller requests a checkpoint during playback and lifecycle transitions;
ordinary progress checkpoints are gated by a ten-second position change. The
original membership predicate normalizes both each visited playlist URL and the
unchanging current-source URL. It performs that scan even if there is no
collection folder to preserve. The captured playlist index is not used to answer
the membership question.

The final candidate retains PR #140's early source-identity validation, skips
the membership check when the folder or playlist is absent, and verifies the
item at a valid captured index.
A mismatching, missing, or out-of-range index falls back to a playlist scan.
Singletons go directly to their one-item scan, avoiding a repeated comparison
when the hinted item does not match.
The fallback skips an item already checked by the indexed probe. A lazy-source
alternative was rejected after the malformed-input controls regressed.
The index is only a hint: it never independently proves membership, and the
saved index is not changed. No persistent cache or new ownership is introduced.

Record construction still invokes the existing playlist deduplication routine.
This experiment measures that complete construction, not just the faster
membership predicate. JSON encoding, disk writes, coalescing, UI work, and other
history stores are outside the timing interval.

The timed loop also includes bounded scalar-output checks, checksum consumption,
record disposal, and a per-call autorelease pool on macOS. These costs are shared
by both implementations. Complete output validation and fixture construction
happen outside the timer. Absolute results describe this instrumented component
workload, not the entire persistence queue.

## Frozen comparison and qualification plan

Original-main reference: `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`.

Primary incremental reference:
`2620d561d11c9a7d9396d3b455424a10a6dddcd7`, the pinned implementation in
[concurrent PR #140](https://github.com/Jagalite/illiquid/pull/140).
That proposal already verifies the captured index, skips folderless scans, and
reuses the source key. It is stacked on
[PR #124](https://github.com/Jagalite/illiquid/pull/124), whose normalized linear
scan was inspected at `9f21c84bbe097984642c8fc08b7c8c1fd31a6c41`.
Both appeared while this research was running. This follow-up is stacked on
PR #140 and attributes the principal index shortcut to that proposal. Its
incremental changes are avoiding the separate singleton probe and skipping an
already-probed item during fallback.
The overlapping original-main improvements are not additive or a new claim.

Only `Sources/IlliquidPlayer/Player/PlaybackCheckpointWriter.swift` differs
between the two implementations. Both use identical current supporting Core
sources and the same tests and driver. The staging manifest records source and
executable hashes. The complete checkpoint source is compiled into a separate
`IlliquidPlayer` module; the driver cannot inline its implementation.

The staged Core module includes the complete production `PlaybackSessionRecord`
and `PlaybackSessionStoring` declarations. The unrelated disk-store implementation
is excluded at a checked source boundary. There are no replacement record,
normalization, deduplication, or playlist implementations.

Before evaluating timings, require:

- Baseline and candidate to pass the same semantic tests in debug and release.
- Exact complete-record parity, with only the intentionally fresh `updatedAt`
  timestamp set to a fixed value after checking that it falls within the call's
  time bounds.
- Coverage of valid and stale indices, nil and extreme indices, duplicate
  identities with different metadata, lexical and Unicode aliases, malformed
  source/URL combinations, unsupported authorities, absent sources, no folder,
  remote sources, empty playlists, and snapshot independence.
- Every timing observation to retain and check its result, with all observations
  preserved, including slow samples.

Each full campaign uses eight balanced baseline/candidate pairs per
workload in fresh processes, with warm-up and calibration outside the reported
samples. Each pair uses the same iteration count, sized to measure the faster
implementation for a useful interval. Wall and process CPU time are reported
separately. Workloads include ordinary 32-item playlists and larger 1,000- and
10,000-item collections, early/middle/late membership, index fallback, absent
membership, and unchanged-path controls.

The original-main study's premeasurement target was at least a 15% median paired
reduction in both wall and CPU time for the 1,000- and 10,000-item middle/late
indexed workloads. That hypothesis is superseded as a novel contribution because
PR #140 already implements the indexed shortcut.

Before the first comparison against PR #140, the narrowed target was at least a
15% median paired reduction in both wall and CPU time for `single-absent` and
`unsupported-unicode-1`. These targets are informed by the earlier exploratory
findings; they are not presented as the original hypothesis. The ordinary
matching-index workloads are now unchanged-path controls. A repeatable increase
greater than both 10% and 5 microseconds per record in any control requires
investigation. Controls include unsupported source authorities with unsupported
playlists and a Unicode singleton, because lazy source rejection can add work
on malformed input. These are research decision criteria, not noisy timing
assertions for routine CI. Small statistically unclear differences must be
reported as inconclusive.

That first comparison at `29de8634` met both targeted improvements but failed the
malformed-input controls, so lazy source preparation was removed. Before the
fresh final-source cohort, the retained target is at least a 15% median paired
wall and CPU reduction for `single-absent`; the other 25 workloads are controls,
including the now-abandoned `unsupported-unicode-1` target. The same regression
investigation threshold applies. This is an explicitly narrowed follow-up to a
rejected experiment, not a claim that all earlier hypotheses were confirmed.

Native app integration separately builds the app/test graph and runs checkpoint
and coordinator regression suites using the repository's pinned native SDK.
Component tests, app integration, and live UI/playback qualification are distinct.
No FPS, energy, whole-player responsiveness, or storage-I/O claim follows from
this benchmark.

## Reproduce

Use the repository's Kyoto queue when available, as specified in `AGENTS.md`.
With an isolated toolchain/runner where that queue is unavailable:

```sh
python3 Benchmarks/CheckpointMembership/test_harness.py
python3 Benchmarks/CheckpointMembership/run.py \
  --baseline-ref 2620d561d11c9a7d9396d3b455424a10a6dddcd7 \
  --pairs 8 --target-ms 100 --output /tmp/checkpoint-membership
```

The output directory must be new or empty. The selected baseline must be present
in local Git history. Omitting `--baseline-ref` selects the original-main reference
for historical reproduction; this comparison and the native workflow explicitly
select the pinned PR #140 implementation. Swift 6.1 or newer with bundled Swift Testing and Python
3.9 or newer are required. On macOS the runner records and explicitly selects
the active Xcode SDK. Native CI uses macOS 26 and Xcode 26.6.

`--quick` retains every semantic test and complete-record comparison but measures
six workloads with two pairs and a 20 ms target; it is a mechanics check, not the
confirmatory study. `--tests-only` skips timings. Production sources, tests, driver,
compiler flags, toolchain information, binary hashes, command output, calibration,
every observation, and summaries are retained under `OUTPUT/evidence/`.

The portable and native workflow jobs run the full experiment on the research branch and manual
invocation. PR runs use the short timing cohort and repeat semantic qualification.
A separate job builds the full release app and tests checkpoint, coordinator,
playlist, and session behavior.

## Final measurements

The final campaign ran on GitHub `ubuntu-24.04`, x86_64, Swift 6.4, Python 3.12.3,
with 4 logical CPUs exposed from an AMD EPYC 7763 host. The exact environment,
arguments, source revisions, and compiled-library/driver hashes are retained in
[the manifest](evidence/hosted-linux-final/manifest.json) and
[environment receipt](evidence/hosted-linux-final/environment.json).

There are **416 measurements across 26 workloads**, with 8 pairs per workload:
104 baseline-first and 104 candidate-first pairs. All **98 calibration observations**
and **545 command receipts** are retained. No timed loop fell below the 100 ms
target; the shortest lasted 120.569 ms. No observation was excluded.

Negative changes below mean less time. Absolute columns are separate medians;
percentage columns are medians of paired ratios, so they need not equal the ratio
of the absolute medians. The complete raw observations, ranges, and paired values
are in [summary.json](evidence/hosted-linux-final/summary.json) and the archived
logs. The source, driver, and compiled Core implementation are identical within
each comparison except for the checkpoint production file.

| Workload | Baseline wall, µs | Final wall, µs | Paired wall change | Paired CPU change | Faster pairs, wall / CPU |
|---|---:|---:|---:|---:|---:|
| `valid-32-first` | 144.147 | 144.381 | +0.06% | +0.06% | 4/8 / 4/8 |
| `valid-32-middle` | 144.177 | 144.143 | +0.08% | +0.15% | 4/8 / 4/8 |
| `valid-32-last` | 143.856 | 144.083 | +0.09% | +0.09% | 3/8 / 3/8 |
| `valid-1000-first` | 4,328.911 | 4,334.992 | +0.12% | +0.13% | 2/8 / 2/8 |
| `valid-1000-middle` | 4,345.539 | 4,332.020 | -0.02% | -0.02% | 4/8 / 4/8 |
| `valid-1000-last` | 4,332.979 | 4,362.674 | +0.75% | +0.76% | 2/8 / 2/8 |
| `valid-10000-first` | 44,682.481 | 44,596.970 | -0.36% | -0.36% | 6/8 / 6/8 |
| `valid-10000-middle` | 44,525.417 | 44,728.665 | -0.19% | -0.19% | 4/8 / 4/8 |
| `valid-10000-last` | 44,726.740 | 44,848.756 | +0.58% | +0.58% | 3/8 / 3/8 |
| `nil-index-1000` | 8,477.120 | 8,435.749 | -0.39% | -0.42% | 5/8 / 5/8 |
| `nil-index-10000` | 86,842.309 | 86,776.538 | -0.08% | -0.04% | 4/8 / 4/8 |
| `stale-index-1000` | 8,510.494 | 8,443.160 | -0.80% | -0.78% | 6/8 / 6/8 |
| `stale-first-32` | 148.817 | 147.342 | -0.49% | -0.51% | 5/8 / 5/8 |
| `absent-source-1000` | 8,510.375 | 8,417.522 | -0.78% | -0.72% | 6/8 / 6/8 |
| `no-folder-1000` | 4,333.128 | 4,340.721 | -0.00% | +0.00% | 4/8 / 4/8 |
| `no-folder-10000` | 45,548.405 | 45,318.480 | +0.14% | +0.14% | 3/8 / 3/8 |
| `remote-1000` | 4,360.707 | 4,354.114 | -0.07% | -0.06% | 4/8 / 4/8 |
| `empty` | 0.125 | 0.128 | +2.25% | +2.24% | 0/8 / 0/8 |
| `single-valid` | 8.394 | 8.407 | +1.06% | +1.04% | 3/8 / 3/8 |
| `single-absent` | 12.196 | 8.229 | -32.36% | -32.35% | 8/8 / 8/8 |
| `unsupported-only-1` | 4.286 | 4.246 | -0.86% | -0.86% | 7/8 / 7/8 |
| `unsupported-only-32` | 11.396 | 10.755 | -5.31% | -5.32% | 8/8 / 8/8 |
| `unsupported-unicode-1` | 4.684 | 4.623 | -1.37% | -1.36% | 6/8 / 6/8 |
| `invalid-source-unsupported-32` | 6.372 | 6.331 | -1.16% | -1.15% | 5/8 / 5/8 |
| `invalid-source-unsupported-1000` | 182.390 | 185.530 | +1.70% | +1.73% | 1/8 / 1/8 |
| `invalid-source-unicode-1` | 0.483 | 0.491 | +2.20% | +2.19% | 1/8 / 1/8 |

The primary `single-absent` result saves a median paired **3.968 microseconds of
wall time and 3.967 microseconds of CPU time**. Wall reductions range from 30.00%
to 34.15% across the eight pairs. The baseline normalizes the source once and its
one playlist item twice on a miss; the final candidate normalizes each once.
The existing singleton deduplication path returns without reading the item ID.

Ordinary matching-index workloads are controls. Their small differences do not
support a new general index-lookup speedup claim. The largest percentage increase
was the empty case, +2.25% paired wall time, or about 2.8 nanoseconds per record.
The invalid-source/unsupported-1,000 control was +1.70% / +3.06 microseconds
paired wall time. All 25 controls remain below the combined >10% and >5 µs gate.
This gate is a research decision aid, not a proof of zero cost on every input.

## Correctness and audit

All **43 component tests in seven suites** passed for baseline and candidate in
both debug and release. That comprises nine checkpoint tests and 34 existing
Core tests. Swift 6.4 printed separate Player and Core test summaries. The
original `tests.json` recorded only the last summary (34 tests / six suites);
the preserved raw logs also show all nine checkpoint tests passing. The
[independent audit](evidence/hosted-linux-final/audit.json) records the correct
aggregate, and the runner's receipt parser was subsequently repaired and checked
against both the Swift 6.3 combined logs and these Swift 6.4 split logs. Original
receipts are retained unchanged. The reporting fix does not change production,
fixtures, timing loops, or the results of this campaign.

All **151 complete records** match across the four configurations. Verification
checks source enum and URL representations, every playlist item's fields and
ordering, first-duplicate metadata, subtitles, dates, saved indices, shuffle IDs,
position sanitization, pause state, and the original folder representation.
The newly generated timestamp is checked against call boundaries before being
fixed for deterministic comparison. The identical canonical output SHA-256 is
`3b28dfc8627cae220b4340399709e704c1874f5ea0a2163e2ce71865f182744e`.

An independent post-run audit recomputes source and log hashes, complete-record
fingerprints, timed checksums, calibration progression, execution order, and every
summary from the retained evidence. The hosted artifact does not include the
compiled executables; its binary hashes are recorded compilation provenance,
not independently rehashed binaries. The original artifact ZIP was downloaded
and matched GitHub's published SHA-256 before extracting the evidence. The
[retrieval receipt](evidence/hosted-linux-final/retrieval.json) identifies that
artifact and the exact successful job.

The native workflow is configured to build the release `Illiquid` application with
the pinned SDK and runs the inherited checkpoint suites, the new membership
suite, the full coordinator suite, and the selected Core suites. Its receipt
requires the inherited six-method XCTest suite as well as nonempty Swift Testing
results. Native qualification is pending; follow
[the workflow history](https://github.com/Jagalite/illiquid/actions/workflows/checkpoint-membership.yml)
for the latest jobs. Those checks are separate from the completed Linux component
evidence. No live playback,
restore/shutdown integration, macOS performance, FPS, energy, or disk-latency
success is inferred from the portable run.

## Research history and rejected alternatives

The original work began against main before the overlapping PRs appeared. The
proposal was narrowed to a follow-up on PR #140 after inspecting both #124 and
#140. Earlier original-main savings are not additive to those proposals and are
not attributed to this final refinement. All earlier measured campaigns and the
infrastructure failure are preserved with explicit classifications.

| Evidence | Candidate / baseline | Disposition |
|---|---|---|
| [Linux smoke](evidence/linux-smoke/audit.json) | `3e0af482` / original main `ea2ff568` | 24 observations; mechanics only, no performance conclusion. |
| [Initial full Linux](evidence/linux-initial/audit.json) | `3e0af482` / `ea2ff568` | 320 observations; rejected after the singleton-miss regression. |
| [Interrupted attempt](evidence/linux-interrupted/audit.json) | `78f182c4` / `ea2ff568` | Compiler disk exhaustion; zero timing or completed-test results. |
| [Singleton correction](evidence/linux-singleton-fix/audit.json) | `78f182c4` / `ea2ff568` | 320 observations; superseded exploratory index-shortcut evidence. |
| [Rejected lazy source](evidence/linux-lazy-rejected/audit.json) | `29de8634` / PR #140 `2620d561` | 416 observations; both targets improved, but malformed-input controls regressed. |
| [Final hosted Linux](evidence/hosted-linux-final/audit.json) | `c98d899b` / `2620d561` | 416 observations; retained singleton target met, no control crossed the gate. |

Each evidence directory contains an `evidence.tar.gz` archive of all original
files, readable primary receipts, and an audit with its archive digest and file
inventory. These are durable copies of the evidence, independent of Actions
artifact retention. Compiled binaries are excluded from the archives.

### Initial singleton regression

The first complete original-main cohort improved the indexed middle/late groups
in all eight CPU and wall pairs. However, `single-absent` crossed the original
investigation gate: +63.33% / +11.30 µs paired wall and +48.68% / +6.71 µs paired
CPU time. Its valid but nonmatching hint led to a second normalization of the
only playlist item. Sending singletons directly to one scan corrected that
structural cost.

The subsequent original-main cohort kept all primary indexed reductions above
15%, but became superseded when PR #140 supplied the same principal shortcut.
Its singleton-miss control was +8.73% / +1.27 µs wall, and the stale-first control
was +9.90% / +18.76 µs. Those adverse observations remain in the archive. A
separate attempt before that completed cohort failed during compilation because
the shared scratch filesystem filled; it contains no timing observations and is
not counted as a performance repetition.

### Rejected lazy source normalization

The first direct comparison with PR #140 used lazy source preparation. It
improved `single-absent` by 35.04% paired wall/CPU and
`unsupported-unicode-1` by 98.02%, satisfying its two narrowed targets. It also
introduced concrete costs on malformed inputs:

| Control | Paired wall change | Paired CPU change | Slower pairs |
|---|---:|---:|---:|
| Valid 10,000-item last match | +11.28% | +11.30% | 6/8 |
| Invalid source, 1,000 unsupported items | +31.13% | +31.14% | 7/8 |
| Invalid source, one raw Unicode item | +1,142.67% | +1,146.15% | 8/8 |

For 1,000 unsupported items, lazy preparation performed an unnecessary membership
pass before returning. For the raw Unicode singleton, median wall time rose from
0.855 to 10.978 µs. The baseline rejected the source before touching the item;
singleton deduplication already avoids normalizing it. The lazy implementation
introduced that expensive normalization. These structural regressions caused the
proposal to be rejected, and the ordinary last-match adverse result was also
retained without exclusion.

The final source restores the baseline's eager source guard. Its confirmation is
a fresh campaign on an isolated hosted runner, using the exact final source and
the same 26 workload fixtures. The large unsupported-input gains from the rejected
lazy implementation are not a claim for the final code.
