# Subtitle memory-budget performance research

Date: October 17, 2026. Baseline: `8c3cc3d4008d5d1b8d436bcf2d51d891382b6548`.

## Decision

Adopt the small change in `SubtitleMemoryBudget`: return immediately for an unchanged, admitted resize, and accumulate total/owner reservations in one pass for acquisition and actual size changes. Keep the original reservation table and ownership model.

The final optimized macOS arm64 experiment found 61–81% less time for unchanged resizes, 23–41% less for actual size changes, and 51–62% less for acquisition/release with 32–128 live leases. Linux results corroborated those improvements. Small-count acquisition/release results were close to baseline, with overlapping ranges. These are component bookkeeping improvements. The absolute savings are fractions of a microsecond in most cases; whole-player CPU, responsiveness, physical memory and energy gains have not been measured.

A larger cached-total prototype was rejected after it made low-count acquisition/release substantially slower. Its source and all measurements are retained below.

## Why this path

The [baseline budget](https://github.com/Jagalite/illiquid/blob/8c3cc3d4008d5d1b8d436bcf2d51d891382b6548/Sources/IlliquidNativePlayback/Subtitles/SubtitleMemoryBudget.swift) reduces all reservations to find total bytes, then filters the table by owner and reduces the resulting collection. Both acquisition and resizing do this while holding `NSLock`, including resizes to the lease's current byte count.

[ASSSubtitleFramePacker](../Sources/IlliquidNativePlayback/Subtitles/MetalASSSubtitleCompositor.swift) requests a resize from `prepareAtlas` and `prepareBGRA` whenever it prepares a nonempty subtitle frame. Its staging buffers grow and are reused, so repeated requests can have identical sizes. [SubtitleDecoder](../Sources/IlliquidNativePlayback/Media/SubtitleDecoder.swift) also acquires a lease for each decoded bitmap display event. The [bitmap timeline](../Sources/IlliquidNativePlayback/Subtitles/BitmapSubtitleTimeline.swift) admits up to 128 events, bounded by 32 MiB.

These calls do not occur on every video frame universally. Main/PiP packing is gated by changed or newly presented subtitle content. Typical text playback has only a few libass/staging leases. Dense bitmap events can produce a larger live set; main/PiP share an event's lease. The workload matrix includes both small and dense sets, without treating animated text plus a full bitmap timeline as typical playback.

This investigation is independent of packet queues, decoding, thumbnail scheduling, persistence, folder discovery, external subtitle matching/import, and playlist restoration work.

## Production change and correctness

The unchanged-size return occurs after lookup of an existing lease under the original lock. It is safe because the limits are immutable and the existing reservation already passed admission. A lease whose weak budget has been destroyed still returns failure through the existing API.

For requests that require accounting, a single loop computes the same nonnegative total and owner sums as the previous reductions/filter. There are no cached totals to maintain. The source-level temporary filtered collection is removed; allocation counts or RSS savings were not measured.

Reservation admission, failure counters, aggregate/owner limits, zero-byte reservations, weak budget ownership, release, preflight and snapshot semantics are preserved. The final production diff is 15 added lines and eight removed lines in one file. Acquisition and changing-resize accounting remain O(live leases); an unchanged resize performs only the existing dictionary lookup and validation of equality.

## Final macOS measurements

The [macOS qualification run](https://github.com/Jagalite/illiquid/actions/runs/39043771647) passed all 11 accounting test functions in both debug and release, with warnings as errors, and completed all 360 benchmark processes. It used macOS 26.6.2 arm64, Apple Swift 6.3.3, explicit Swift 6 language mode, and optimized whole-module builds. The hosted runner exposed three CPUs. The production source, baseline, harness, and runner hashes match the Linux qualification inputs; absolute timings are compared only within each platform cohort.

These are median nanoseconds per operation from six fresh processes per variant/workload, using the balanced method described below. The live count is the retained set before a temporary acquisition. Negative values in the last column indicate more time.

| Operation | Live leases | Baseline median (ns) | Final median (ns) | Less time |
|---|---:|---:|---:|---:|
| Unchanged resize | 1 | 257.9 | 99.9 | 61.3% |
| Unchanged resize | 4 | 274.2 | 93.8 | 65.8% |
| Unchanged resize | 32 | 298.9 | 108.3 | 63.8% |
| Unchanged resize | 128 | 520.3 | 98.9 | 81.0% |
| Changing resize | 1 | 255.4 | 164.8 | 35.5% |
| Changing resize | 4 | 259.3 | 189.2 | 27.0% |
| Changing resize | 32 | 324.5 | 189.9 | 41.5% |
| Changing resize | 128 | 530.1 | 408.6 | 22.9% |
| Acquire + release | 1 | 442.3 | 454.2 | -2.7% |
| Acquire + release | 4 | 501.2 | 454.1 | 9.4% |
| Acquire + release | 32 | 1032.5 | 503.7 | 51.2% |
| Acquire + release | 128 | 1863.5 | 702.1 | 62.3% |

Unchanged-resize ranges and dense-set acquisition/release ranges are completely separated from baseline in this cohort. Actual-resize medians are lower at every count, but the ranges overlap at 1, 4, and 32 leases; this is not a claim that every run was faster. Small-set lifecycle ranges overlap substantially, including the 2.7% higher median at one lease. The unchanged preflight/snapshot controls range from 6.9% more time to 14.7% less time, with overlapping ranges, so no gain is attributed to those methods. The shared macOS runner was noisier than the Linux cohort.

The same-size-only ablation reproduces the unchanged-resize improvement. Its acquisition/release and changing-resize results remain near baseline, supporting the combined accounting loop as the cause of the additional improvements. The [native summary](../Benchmarks/SubtitleMemoryBudget/evidence/final-macos/summary.json), [360 raw observations](../Benchmarks/SubtitleMemoryBudget/evidence/final-macos/measurements.jsonl), [manifest](../Benchmarks/SubtitleMemoryBudget/evidence/final-macos/manifest.json), and [Actions provenance](../Benchmarks/SubtitleMemoryBudget/evidence/final-macos/provenance.json) are preserved in Git, beyond the artifact's retention period. A separate review checked the source identities, balanced orders, receipts, timing arithmetic, and summaries.

## Final Linux measurements

The table reports median nanoseconds per operation from six fresh processes per variant/workload. Acquisition/release is one complete lease lifecycle; the listed count is the retained set before that temporary lease is acquired. Small differences at one/four leases overlap the measured ranges and are not claimed as meaningful lifecycle speedups.

| Operation | Live leases | Baseline median (ns) | Final median (ns) | Less time |
|---|---:|---:|---:|---:|
| Unchanged resize | 1 | 139.2 | 47.4 | 65.9% |
| Unchanged resize | 4 | 148.1 | 50.6 | 65.8% |
| Unchanged resize | 32 | 185.8 | 48.0 | 74.2% |
| Unchanged resize | 128 | 325.0 | 47.0 | 85.5% |
| Changing resize | 1 | 148.4 | 105.1 | 29.2% |
| Changing resize | 4 | 145.6 | 109.6 | 24.7% |
| Changing resize | 32 | 188.4 | 137.3 | 27.1% |
| Changing resize | 128 | 306.8 | 228.7 | 25.5% |
| Acquire + release | 1 | 218.0 | 211.3 | 3.1% |
| Acquire + release | 4 | 248.1 | 230.9 | 6.9% |
| Acquire + release | 32 | 599.2 | 257.5 | 57.0% |
| Acquire + release | 128 | 1151.2 | 367.9 | 68.0% |

The unchanged preflight and snapshot method bodies were measured as controls. Their median differences ranged from about 4.1% slower to 5.3% faster, with overlapping ranges; no performance improvement is attributed to those methods. Changing resize at 128 leases also had an overlapping high outlier despite a lower median. Full minima/maxima and individual observations are in the [final summary](../Benchmarks/SubtitleMemoryBudget/evidence/final-linux/summary.json) and [raw rows](../Benchmarks/SubtitleMemoryBudget/evidence/final-linux/measurements.jsonl).

The same-size-only ablation isolates the first optimization. It delivers essentially the unchanged-resize benefit. The combined loops are what reduce actual-resize cost and dense-set acquisition/release in the final variant.

### Method and scope

- Actual production Swift source, not a reimplementation. The frozen baseline Git blob is `7694b209c13e86406fc2eac6bef2c7ed09974569`.
- Swift 6.3.2 on Linux x86_64, AMD EPYC 9V74 host, with an eight-CPU cgroup quota. The final build explicitly uses Swift 6 language mode, `-O`, whole-module optimization, and warnings as errors.
- Three variants: baseline, baseline plus unchanged-size return, final production source. Four live counts (1, 4, 32, 128) and five operations. All six variant permutations are used for every case; each variant occupies every position twice. Case order reverses between rounds.
- 360 final timing processes per platform cohort. Each performs 2,000 warmup operations and 500,000 timed operations. Setup, final state verification, JSON serialization and process startup are outside the timer. The snapshot workload consumes all owner values through a stable weighted receipt.
- Every process verifies successful operations and final complete-snapshot parity. The runner compares receipts between variants. A separate post-run check verified all 360 identities, permutations, timing arithmetic, receipts, source hashes and medians.
- Synthetic reservation sizes represent bookkeeping cardinality. They do not allocate corresponding pixel buffers, invoke libass, render subtitles, or model whole-player event frequencies. Reported per-operation results include loop/call overhead. The shared-host environment and process-specific hashing limit interpretation of small differences.

The tested final source SHA-256 is `9ed5a5969fe23ae90df38aea7987f5a61feeb10d7aa1ffafbcf0c05917974cac`. Compiler commands and source/binary identities are recorded in the [manifest](../Benchmarks/SubtitleMemoryBudget/evidence/final-linux/manifest.json).

## Rejected cached-total experiment

The initial prototype kept aggregate bytes and per-owner bytes/lease counts. It greatly reduced snapshot/preflight cost and helped dense reservations, but added extra dictionary updates to each acquisition and release.

In its own controlled Linux cohort, acquisition/release at one live lease increased from 194.2 to 335.1 ns (73% more time), and at four leases from 213.7 to 411.5 ns (93% more). Actual size changes at one/four leases were 15–18% slower. The strongest snapshot gains were not representative of steady-state playback: [NativePlaybackRuntime](../Sources/IlliquidNativePlayback/Production/NativePlaybackRuntime.swift) exposes the budget snapshot through `subtitleMemoryBudgetSnapshotForTesting`; `canAcquire` is used for candidate pipeline admission during replacement.

The final single-pass design avoids this extra mutable accounting and the observed small-set lifecycle penalty. The [cached prototype](../Benchmarks/SubtitleMemoryBudget/experiments/CachedSubtitleMemoryBudget.swift) is an experimental input only and is outside production targets. Its [summary](../Benchmarks/SubtitleMemoryBudget/evidence/cached-experiment/summary.json), [360 raw observations](../Benchmarks/SubtitleMemoryBudget/evidence/cached-experiment/measurements.jsonl), and [manifest](../Benchmarks/SubtitleMemoryBudget/evidence/cached-experiment/manifest.json) preserve the negative results.

The initial cohort used the compiler's default Swift 5 language mode; the final qualification explicitly uses Swift 6. Comparisons above are within each cohort. Absolute values from the two cohorts are not subtracted from one another, and the prototype's Linux regressions are not presented as measured macOS regressions.

## Correctness validation

The [regular native-target test file](../Tests/IlliquidNativePlaybackTests/SubtitleMemoryBudgetAccountingTests.swift) also runs through the [isolated Foundation runner](../Scripts/test-subtitle-memory-budget.sh). The tests were written independently of the optimization.

- All 11 test functions passed against the final source in both debug and release, with warnings treated as errors.
- All 11 passed against the original source in release, establishing baseline semantic equivalence for this coverage.
- Four seeds across four configurations execute 32,000 modeled operations. The oracle reconstructs complete hypothetical reservation lists and owner snapshots, without reusing production accounting code.
- Coverage includes limits, missing/zero/negative owner limits, negative request normalization, duplicate preflight owners, failure counts, shrinking, zero-byte owners, retained snapshots, aliased leases, orphaned budgets, `Int.max`, and final cleanup.
- Concurrent tests check independent acquisition/release against a known retained baseline, exact rejected-mutation counts, atomic snapshot/capacity invariants, and simultaneous resizing of shared leases.
- A deliberately broken resize implementation compiled, then failed the focused rejection test with seven assertion issues. The [mutant diff](../Benchmarks/SubtitleMemoryBudget/evidence/validation/rejected-mutant.patch) is evidence only.

[Validation logs and source identities](../Benchmarks/SubtitleMemoryBudget/evidence/validation/) accompany the measurements. Independent source/benchmark/test review found no blocking issue.

## macOS qualification and reproduction

A dedicated [macOS workflow](../.github/workflows/subtitle-memory-budget.yml) runs the actual-source accounting tests in debug/release and the same balanced three-variant benchmark with the repository's pinned Xcode environment. It uploads platform-specific raw evidence. The successful run and its measurements are recorded above; subsequent CI status is available in the PR.

```sh
bash Scripts/test-subtitle-memory-budget.sh --jobs 2 -Xswiftc -warnings-as-errors
bash Scripts/test-subtitle-memory-budget.sh --jobs 2 -c release -Xswiftc -warnings-as-errors
python3 Benchmarks/SubtitleMemoryBudget/run.py --output /tmp/illiquid-budget-results
```

The output directory must not already exist. [Benchmark instructions](../Benchmarks/SubtitleMemoryBudget/README.md) cover the preserved prototype. Full visible playback, rendered pixel parity, Instruments, physical footprint and energy measurement remain outside this component result.
