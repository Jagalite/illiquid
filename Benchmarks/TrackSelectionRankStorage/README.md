# Track selection rank storage

This experiment isolates temporary ranking storage in the complete production
`TrackSelectionPreferences.select` implementation. The frozen baseline is
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`: it already caches the incumbent
rank and skips ranking for empty/singleton catalogs. Comparing against that
revision avoids attributing the earlier ranking optimization to this change.

Both variants compile the entire selection source and the same production
`MediaTrack.swift` as separate optimized shared modules. The new runner
reuses the existing
[TrackSelectionRanking harness](../TrackSelectionRanking/Harness.swift) for
all workloads and the complete 55,296-selection differential receipt. A
fail-closed staging adapter changes only the measurement boundary and receipt
fields, then appends [Measurement.swift](Measurement.swift). It does not copy
or replace the production selection algorithm. The historical benchmark and
its frozen baseline remain unchanged.

## Measured result (Linux)

The change removes transient rank storage while preserving selected track IDs. On the
Linux x86_64 Swift 6.4 / glibc 2.39 runner, the 2-, 8-, and 32-track audio cases
without a language policy improved in all ten timing pairs. Their median paired wall
reductions were **11.55%, 20.20%, and 23.60%**. Subtitle Always with eight tracks
improved **19.46%**, also in all ten pairs. CPU-time reductions closely matched wall time.

The actual 32-track allocation saving is **31 successful allocation requests and
2,728 requested bytes per selection**, including with a language policy. The measured
counts differ from a literal source-level count of rank arrays; this report uses the
observed counts and does not infer how the compiler lowered rank storage.
These are transient requested bytes, not a reduction in retained heap or process RSS.

Linux correctness passed **13 tests in each baseline/candidate debug/release run**
(52 executions), plus exact parity for all **55,296 selected-ID cases** in both the
timing and allocation cohorts. Every one of the 320 final timing observations exceeded
the 60 ms wall/CPU floor (minimum wall 89.628 ms; CPU 89.641 ms). All 128 allocation
observations were retained, and their per-selection counters were identical across
each workload/variant's four observations.

Native macOS qualification is **pending**: the macOS 26 job in the same run is queued.
The supported success claim is the Linux portable-component allocation and timing
improvement. Full-app and native performance claims require their own evidence.

### All workloads

Values below are per selection. Time columns are medians of the individual arms;
the percentage column is the median of paired reductions, so it need not equal the
ratio of the two time medians. Positive percentages mean less time.

| Workload | Wall ns, baseline → candidate | Paired wall reduction | Faster pairs | Allocation requests, baseline → candidate | Requested bytes saved |
|---|---:|---:|---:|---:|---:|
| `audio-0-none` | 74.290 → 74.263 | 0.045% | 7/10 | 0 → 0 | 0 |
| `audio-0-languages` | 7,653.409 → 7,625.803 | 0.296% | 7/10 | 29 → 29 | 0 |
| `audio-1-none` | 137.094 → 135.768 | 0.846% | 8/10 | 1 → 1 | 0 |
| `audio-1-languages` | 7,719.720 → 7,737.076 | -0.707% | 2/10 | 30 → 30 | 0 |
| `audio-2-none` | 297.770 → 263.208 | 11.553% | 10/10 | 3 → 2 | 88 |
| `audio-2-languages` | 13,621.598 → 13,504.347 | 0.900% | 8/10 | 46 → 45 | 88 |
| `audio-8-none` | 881.662 → 703.462 | 20.196% | 10/10 | 11 → 4 | 616 |
| `audio-8-languages` | 29,020.938 → 28,857.572 | 0.572% | 8/10 | 89 → 82 | 616 |
| `audio-32-none` | 3,045.380 → 2,325.559 | 23.600% | 10/10 | 37 → 6 | 2728 |
| `audio-32-languages` | 90,412.689 → 90,054.405 | 0.334% | 6/10 | 255 → 224 | 2728 |
| `subtitle-automatic` | 484.970 → 484.124 | 0.252% | 6/10 | 4 → 4 | 0 |
| `subtitle-off` | 2,352.047 → 2,345.576 | 0.468% | 7/10 | 10 → 10 | 0 |
| `subtitle-always` | 910.093 → 732.363 | 19.464% | 10/10 | 11 → 4 | 616 |
| `subtitle-forced-languages` | 31,804.328 → 31,786.385 | 0.269% | 6/10 | 85 → 83 | 176 |
| `subtitle-forced-audio-fallback` | 19,890.041 → 19,818.423 | 0.463% | 6/10 | 49 → 48.5 | 44 |
| `mutable-preferences` | 37,856.505 → 37,824.011 | 0.372% | 6/10 | 98.5 → 93 | 484 |

All six unchanged-path allocation controls stayed unchanged. Language-policy timing
changes are below 1% in paired medians and include large individual-pair swings;
they do not support a reliable speedup claim. The singleton language-policy control
is **0.707% slower** by paired wall median and **0.691% slower** by CPU median, with
unchanged allocations. It is retained in the table and raw observations.

### Retained evidence

- [Workflow run 40637503011](https://github.com/Jagalite/illiquid/actions/runs/40637503011), Linux job `122647743642`, tested commit `e59dd2cf8d539efcd6ec00102b1945230cead5c9`.
- [Artifact receipt](evidence/linux/artifact-receipt.json) records the original ZIP digest and the hashes of the retained files.
- [Independent audit](evidence/linux/audit.json) checked all 667 archive members, source provenance, command/log hashes, complete selected-ID receipts, all observations, and every summary statistic.
- [Timing summary](evidence/linux/timing/summary.json), [raw timing rows](evidence/linux/timing/measurements.jsonl.gz), [allocation summary](evidence/linux/allocations/summary.json), and [raw allocation rows](evidence/linux/allocations/measurements.jsonl.gz) retain the complete workload matrix.
- [Full selected-ID receipt](evidence/linux/verification.json.gz), debug/release test logs, manifests, command receipts, and calibration observations are preserved alongside them. Gzip files decompress to the exact original bytes; hashes are recorded in the artifact receipt.

The CI upload intentionally excludes compiled binaries and Swift module files. Their
build hashes are recorded, but the independent audit could not recompute those binary
hashes. Exact source bytes, staged inputs, command receipts, test output, and raw
measurements were checked. The benchmark remains reproducible from this commit and
its frozen baseline.

## Why the scalar order is equivalent

The six Boolean preferences keep their original priority order in bits 5 through 0:
commentary avoidance, accessibility, dedicated forced subtitle, default flag, subtitle
forced flag, and fallback ID. Language rank occupies the higher bits. Sanitization
bounds language rank to 0…32, so the complete value stays in 0…2111. All lower
priorities together are at most 63 and cannot outweigh one language-rank step.
Equal values still use the unchanged direct signed-ID comparison. An independent
enumeration of all 2,112 abstract rank tuples confirmed the order; the 32-language
regression additionally checks actual selection against opponents favored by every
lower-priority flag and by the signed-ID tie-break.

## Reproduce

Requirements: matching Swift 6.1+ `swift` and `swiftc` tools, Python
3.10+, and a C compiler for the Linux/glibc allocation cohort. Native
qualification uses macOS 26 and Xcode 26.6, matching the existing workflow.

Follow `AGENTS.md`: submit these commands through the shared Kyoto queue
when available. Inspect its show, wait, and logs results. When the queue is
unavailable, state that limitation before running isolated builds directly.
The GitHub workflow performs that check and executes its builds serially.

```sh
python3 Benchmarks/TrackSelectionRankStorage/run.py test \
  --configuration debug --output /tmp/rank-storage-debug
python3 Benchmarks/TrackSelectionRankStorage/run.py test \
  --configuration release --output /tmp/rank-storage-release

python3 Benchmarks/TrackSelectionRankStorage/run.py benchmark \
  --rounds 10 --target-ms 100 --output /tmp/rank-storage-timing

# Separate Linux/glibc instrumentation; these elapsed times are not speed claims.
python3 Benchmarks/TrackSelectionRankStorage/run.py benchmark \
  --allocations --rounds 4 --iterations 1000 \
  --output /tmp/rank-storage-allocations
```

`test` is tests-only; `benchmark` skips the unit-test build and always
runs the full differential comparison before collecting measurements. Each
test command runs both baseline and candidate. `--variant` can restrict a
test invocation. The current `TrackSelectionRankingTests.swift` is staged
identically into both isolated packages, including the 32-language priority
boundary test. The packages fetch no external dependencies.

Use `--swiftc` / `SWIFTC` and `--swift` / `SWIFT` to select a
toolchain; the runner prefers `swift` beside the chosen compiler.
`--cc` / `CC` selects the allocation-meter C compiler. On Linux,
`--cpu N` pins the runner and all child processes to an allowed CPU.
All generated source, logs, builds, and caches stay under `--output`;
`HOME` is unchanged. Each new invocation requires a fresh output directory.

A short build/parity smoke run can target one workload:

```sh
python3 Benchmarks/TrackSelectionRankStorage/run.py benchmark \
  --rounds 2 --iterations 100 --workload audio-2-none \
  --output /tmp/rank-storage-smoke
```

Add `--allocations` to smoke-check the separate meter build. Repeat
`--workload` to select more cases. Smoke times are not performance evidence and normally produce an unqualified
timing receipt because their intervals are deliberately short.
Regenerate a summary without rebuilding or rerunning any observation:

```sh
python3 Benchmarks/TrackSelectionRankStorage/run.py summarize \
  --output /tmp/rank-storage-timing
```

## Workloads and behavior checks

The reused 16-workload matrix contains audio catalogs of 0, 1, 2, 8, and 32
tracks, each with empty and ordered language preferences. It also contains
subtitle Automatic, Off, Always, forced-only with explicit languages,
forced-only with audio-language fallback, and mutable raw preferences.
Zero/singleton audio and subtitle Automatic/Off are unchanged-path controls.

Ordinary iterations make two selections: original/reversed catalog order,
different fallbacks, and an audio catalog variant containing unrelated
subtitles. Mutable preferences make four selections and include the five
public preference assignments. Candidate/input construction, initial
preferences, and warmup stay outside the measured interval. Sanitization,
filtering, normalization, ranking, selected-ID consumption, and temporary
allocation inside `select` remain inside it.

The full differential compares selected-ID arrays, catalog descriptions, and
preference state, not only checksums: 64 raw preference states, 27 catalogs
and ordering variants, both track kinds, four fallback positions, and four
audio-language contexts. Catalogs cover every combination of five track
flags, invalid/aliased languages, and extreme signed 64-bit IDs. Public
preferences include aliases, duplicates, every subtitle policy, and the
32-entry sanitization boundary. Unit tests additionally state independent
semantic expectations.

## Separate timing and allocation cohorts

Measurement commands reject inherited `LD_PRELOAD` or
`DYLD_INSERT_LIBRARIES` before setup, and record that check. Only the
explicit allocation cohort loads its recorded meter. Timing builds do not
compile or link the allocator helper. The independent
optimized driver links each complete production module without cross-module
optimization; it cannot see or hoist `select`'s implementation. Each
selection contributes to checked result fields.

The default timing cohort uses ten balanced AB/BA pairs per workload, each
observation in a fresh process. Separate pilot observations calibrate one
shared iteration count so the faster minimum of wall and process CPU time
across both variants reaches at least 100 ms. Final observations must each
reach 60 ms in both clocks for timing qualification. Short observations are
retained in the raw data and summaries, listed in `qualification.json`,
and mark the entire timing cohort unqualified; none are discarded. CI rejects
an unqualified final cohort. The threshold concerns measurement duration, not
a required speedup. Uninstrumented wall and process CPU time are both retained.
Summaries report
per-selection medians, all within-pair reductions, and favorable-pair counts.
A ratio of separate medians is not substituted for the paired statistic.
No observations are discarded; CI does not require a minimum speedup.

The allocation cohort separately compiles the existing
[StandardCompletionContract meter](../StandardCompletionContract/CCompletionHeap/heap.c).
Only instrumented drivers link/preload it. Counters start after warmup and
stop immediately after the selection batch, before clocks are read or JSON
is serialized. `malloc`, `calloc`, and `realloc` count only
successful intercepted requests. The summary reports request counts and
requested bytes per selection; instrumented elapsed times are excluded.

These counters do not measure retained heap, peak memory, RSS, every
allocator API, or macOS allocation behavior. Timing and allocation receipts
cannot be combined by the summarizer. The allocation default is a fixed
1,000 iterations per workload; the documented/CI cohort uses four balanced
pairs. Native timing is independently measured without a meter.

## Evidence and limits

The workflow runs on pull requests and on pushes only to
`codex/track-selection-rank-storage`, allowing qualification before opening
a PR. Disposable local output can go under the ignored `.work/` directory.

Every invocation preserves pinned Git blob/SHA-256 identities, exact staged
baseline/candidate sources, original/adapted harness, measurement helper,
imported runner helpers, meter source/header, current tests, toolchain
paths/versions/binary hashes, executed commands, and build-product hashes.
Calibration, full differential logs, raw JSONL measurements, per-process
logs, summaries, and completion status are retained. A failed command writes
a failed completion receipt and keeps preceding observations.

Only `TrackSelectionPreferences.swift` differs between the production
modules. The current shared media model must match the pinned manifest.
Inputs and the measurement driver are identical across the pair.

Results describe component selection and temporary allocation cost on the
recorded platform. Linux results do not establish native macOS performance.
The workloads do not measure file-open latency, decoder throughput, frame
delivery, whole-player memory, or interactive playback. Catalog size and
language normalization can change how much ranking storage contributes to
total cost. Native CI publishes its own portable-component measurements;
building these two production files does not qualify the complete app or UI.
