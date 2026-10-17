# Subtitle memory budget: avoid rescanning unchanged reservations

## Decision

Keep the same-size resize shortcut in `SubtitleMemoryBudget.Lease`. After finding
the live reservation under the existing lock, return success when the normalized
request equals the bytes already admitted. The production change adds three
lines, including its explanation.

This is a measured reduction in a small bookkeeping operation. It is not evidence
of a measurable whole-player CPU, memory-footprint, energy, or frame-latency gain.
The broader cached-accounting alternative was rejected after it slowed ordinary
small-reservation cases.

Base: `8c3cc3d4008d5d1b8d436bcf2d51d891382b6548`. The investigation is independent
of packet queues, thumbnail scheduling, history persistence, folder discovery,
subtitle import/matching, and video frame preparation work in other PRs.

## Why this operation is called

`ASSSubtitleFramePacker.prepareAtlas` and `prepareBGRA` calculate the total size of
their reusable staging buffers and call `memoryLease.resize` before preparing a
frame. These buffers retain their high-water sizes, so accepted preparation can
repeatedly request the same number of bytes. The original budget scans every live
reservation for the total, filters them for the owner, reduces that temporary
collection, validates the request, and rewrites the unchanged reservation.

The main subtitle pipeline owns one libass cache lease and one staging lease.
An initialized PiP compositor adds staging, and its active subtitle pipeline adds
libass and staging leases: about five total. Old/candidate source replacement
can temporarily add another four. Bitmap decoding creates a shared lease per
display set, including zero-byte clears; each timeline defaults to 128 entries
and 32 MiB, so larger reservation counts are a valid stress case. Main and PiP
copies share a bitmap lease rather than charging it twice.

Source references, all relative to the base revision:

- [Frame-packer capacity checks](../Sources/IlliquidNativePlayback/Subtitles/MetalASSSubtitleCompositor.swift)
- [Main/PiP pipeline leases and presentation guard](../Sources/IlliquidNativePlayback/Subtitles/SubtitlePipeline.swift)
- [PiP compositor and prepared-frame reuse](../Sources/IlliquidNativePlayback/Presentation/PiPSubtitleCompositor.swift)
- [Bitmap reservation creation](../Sources/IlliquidNativePlayback/Media/SubtitleDecoder.swift)
- [Bitmap timeline limits](../Sources/IlliquidNativePlayback/Subtitles/BitmapSubtitleTimeline.swift)
- [Candidate admission and subtitle observation cadence](../Sources/IlliquidNativePlayback/Production/NativePlaybackRuntime.swift)

The observation policy follows source frame rate, clamped to 24–120 ticks per
media-time second, with a 30 Hz fallback. This is **not** the budget call rate:
unchanged subtitle frames are skipped or reused. Animated ASS and geometry
changes can trigger more preparation; ordinary static cues generally trigger
far fewer budget calls. No live workload call-rate measurement was performed.

## Experiments and selection

Three complete Swift budget implementations were compared against one harness:

1. The exact production baseline.
2. Cached aggregate and owner totals, including owner lease counts to preserve
   zero-byte snapshot keys, plus a same-size shortcut.
3. Only the same-size shortcut.

The initial matrix included unchanged, changing, and rejected resizes;
acquire/release churn; candidate preflight; snapshot reads; and retained snapshots
interleaved with mutations. It used 1, 2, 5, 9, 32, and 128 live reservations,
six balanced rounds, and 100,000 operations per process: **756 processes**.
Every paired checksum and final accounting receipt matched.

Cached totals made dense-reservation and diagnostic-snapshot cases cheaper, but
its additional dictionary bookkeeping slowed changing resizes by approximately
47–54% and acquire/release churn by 67–74% at two and five leases, using ratios of
the exploration's medians. Snapshot access is testing-only in the inspected
runtime, so its especially large improvement does not establish a playback win.
The rejected source and raw observations are retained under
`Benchmarks/SubtitleMemoryBudget`.

The same-size-only variant captured the main recurring-work benefit while
leaving the growth, release, preflight, and snapshot algorithms intact. Its
correctness argument is substantially smaller, so it was selected.

The short exploration showed noisy outliers in untouched controls. Its optimized
resize samples lasted only about 5 ms, and its executables had different Swift
module names. The final run increased loops tenfold, used the same explicit
module name, and recorded paired comparisons. Those methodological changes are
why the final matrix below is the primary result.

## Final Linux result

Environment: Swift 6.3.2, x86_64 Linux, optimized whole-module compilation, one
process per observation, deterministic Swift hashing. Eight balanced AB/BA rounds
cover four scenarios at 1/2/5/9/128 leases, each with 1,000,000 operations:
**320 processes**. No local test/compiler jobs were running concurrently with
the measured processes; this remains a shared host with uncontrolled background
load and CPU frequency.

### Unchanged-size resize

| Live reservations | Baseline median | Candidate median | Reduction from medians | Median paired reduction |
|---:|---:|---:|---:|---:|
| 1 | 138.9 ns | 47.9 ns | 65.5% | 65.1% |
| 2 | 140.9 ns | 65.4 ns | 53.6% | 59.5% |
| 5 | 142.5 ns | 51.1 ns | 64.1% | 65.4% |
| 9 | 185.9 ns | 47.8 ns | 74.3% | 73.9% |
| 128, stress | 352.5 ns | 46.4 ns | 86.8% | 85.8% |

The first percentage divides the two time medians. The paired percentage takes
the median of the eight within-round candidate/baseline changes; these are
different statistics and need not match. All candidate unchanged-size samples
were faster than all baseline samples for their corresponding count. Full
min/max ranges, individual timings, and paired changes are in the evidence.

The absolute saving at ordinary reservation counts is about 0.08–0.14 microseconds
per call. As a scale illustration, 0.1 microseconds multiplied by 120 calls per
second is 12 microseconds per second for one caller. This arithmetic is not a
measured player CPU reduction. The case for merging is cheap removal of repeated
work with a tiny correctness surface, not a material end-to-end speed claim.

### Controls and limits

| Scenario | 2 leases: median paired change | 5 leases | 9 leases | 128 leases |
|---|---:|---:|---:|---:|
| Changing resize | −1.3% | +5.7% | +0.2% | +7.2% |
| Rejected resize | −0.3% | +9.3% | +11.5% | +0.9% |
| Acquire/release, unchanged implementation | −3.8% | +3.8% | −2.8% | +2.4% |

Negative means faster; positive means slower. These controls overlap in their
raw timing ranges and retain host/code-layout variability. The growth/rejection
paths now execute one extra equality check, so no zero-cost claim is made for
those paths. The data do not establish a consistent general-purpose budget API
speedup. The targeted, warmed-up unchanged-size path is the accepted result.

The harness uses actual locks, leases, weak references, and budget methods, but
fixed synthetic 4 KiB reservations. It measures single-thread accounting, not
contention latency, real bitmap payloads, native frame preparation, rendered
output, or physical RAM. It does not count allocator calls; removing the filter
on the fast path is a source-level fact, not an allocation-profile measurement.

## Correctness and verification

The early return follows the reservation lookup inside the existing `NSLock`.
Both total and owner limits are immutable, and all live reservations were
already admitted. Normalizing a negative request to zero still happens before
the lookup. Therefore an unchanged-size request cannot newly exhaust a limit.
No reservation, rejection count, owner key, or lease lifetime needs to change.
An expired weak budget still returns false before reaching this code.

The standalone runner compiles the actual source unchanged into a temporary
Swift package with the toolchain's `Testing` module. Both the saved baseline and
the final candidate passed debug and release: **8 test functions, 12 executions
after parameterization, in each of four runs**. Each run includes:

- 12,000 deterministic mixed operations checked against an independent
  reservation model, including admission, changed and unchanged resize, release,
  preflight, and snapshots.
- Full global/owner budgets, denied growth, duplicate owner requests, negative
  normalization, zero-byte owner-key lifetime, and immutable saved snapshots.
- A lease outliving its budget.
- Saturated parallel admission and resize, plus 512 concurrent
  acquire/resize/release churn cycles.

All 320 final benchmark behavior receipts match across variants. An independent
source and harness review found no blocking correctness or lifetime issue.
The Linux SwiftPM driver needed `SWIFT_USE_OLD_DRIVER=1` to avoid a container
process-statistics crash; the test runner does not hardcode this setting.

At initial PR creation, the dedicated macOS workflow is pending. It repeats
the focused tests and the final benchmark, and separately builds the app graph
and runs `SubtitleMemoryBudgetTests`, `MetalASSSubtitleCompositorTests`,
`PiPSubtitlePipelineTests`, `BitmapSubtitleTests`, and `PGSSubtitleCropTests` with
the repository's pinned native dependencies. macOS outcomes should be read from
the PR's checks and subsequent report updates. Physical-device playback,
footprint, and energy profiling remain outside this component claim.

## Reproduction and evidence

Commands and complete evidence locations are in
[Benchmarks/SubtitleMemoryBudget/README.md](../Benchmarks/SubtitleMemoryBudget/README.md).
The saved baseline is verified against Git blob
`7694b209c13e86406fc2eac6bef2c7ed09974569`. Final evidence includes source and binary
hashes, all process-order records, losslessly compressed raw observations,
summary statistics, and all four focused-test logs.
