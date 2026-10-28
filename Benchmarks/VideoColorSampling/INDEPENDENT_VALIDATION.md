# Independent native validation and consolidation

## Decision

The native evidence supports resolving the video color sampler's buffer layout
once per accepted frame. This report independently checks the already measured
implementation at `c60321fc2418bbb9bb801e85388bd95fcc4dccb5`, against main at
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`.

Concurrent research produced equivalent layout-hoisting candidates. This
qualification belongs to the implementation with nonescaping `sampleGrid`
closures in the measured commit. It does not establish the performance of the
separate `LockedPixelLayout` enum prototype on
`perf/video-color-sampling-20261028-563b8`, whose native runs were still queued
when this report was prepared. A single production PR avoids overlapping changes.

Only `Sources/IlliquidNativePlayback/Presentation/VideoFrameColorSampler.swift`
changes in production. Pointers and row strides remain local to the existing
CoreVideo read lock. There is no cache between frames, and the grid coordinates,
color conversion, range handling, throttling, and smoothing rules are preserved.

## Native result

[Successful qualification run](https://github.com/Jagalite/illiquid/actions/runs/40635423170)
on Apple M1 virtual hardware, macOS 26.6.2, Apple Swift 6.3.3, and Xcode 26.6.
The metric is elapsed wall time per complete `sample()` call, including native
locking, metadata access, 96-point sampling, result allocation, and consumption
of all color components in a checksum. Fixture creation/filling is excluded.

The 1080p results below use independently recomputed medians of eight
observations per variant. The reduction column is calculated from those two
time medians; it is distinct from the median of the eight paired reductions.

| Format | Baseline median | Candidate median | Reduction from time medians | Median paired reduction |
| --- | ---: | ---: | ---: | ---: |
| BGRA | 6.435 µs | 3.457 µs | 46.28% | 45.31% |
| NV12, video range | 10.789 µs | 4.367 µs | 59.52% | 61.45% |
| NV12, full range | 11.130 µs | 4.008 µs | 63.99% | 64.90% |
| P010, video range | 11.261 µs | 3.945 µs | 64.97% | 65.01% |
| P010, full range | 12.333 µs | 4.487 µs | 63.62% | 60.82% |

Across all 15 format/size cases (48×32, 1080p, and 4K), every one of the **120
paired comparisons** favored the candidate. The complete campaign contains
**240 observations**. Median paired reductions span **40.95%–65.87%**. Median
paired absolute savings at 1080p span **2.741–7.832 µs per accepted sample**.

Eight observations did not meet the nominal 30 ms calibration target: all eight
candidate P010 full-range 1080p samples ran for 15.7–22.4 ms. They remain in the
raw evidence and summaries. No observations were discarded, and all eight
pairs still favored the candidate. The shared virtual host exhibits visible
timing variation; the range and pair data should accompany the medians.

## Independently checked correctness and provenance

- All nine retained source/driver hashes and both isolated package hashes
  match their declared inputs. Six candidate source, test, harness, and runner
  files fetched from the immutable Git commit match the artifact byte-for-byte.
- Baseline and candidate verification records are exactly equal: 90 spatial
  and matrix records plus 10 temporal records, including 96 nonnull grids and
  four nil results. This compares **27,648 RGB component bit patterns** without
  converting their hexadecimal IEEE-754 representations to approximate numbers.
- Every timed pair uses the same iteration count, result checksum, warmup
  checksum, buffer layout, and workload metadata. Each case contains four AB
  and four BA pairs.
- Independent recomputation reproduces every reported median, range, paired
  ratio, percentage reduction, and absolute paired saving.
- All 324 recorded commands exited successfully. All 302 calibration/timing
  command outputs match their persisted measurements.
- The isolated native regression suite passes **10 tests in each of four
  configurations**: baseline debug/release and candidate debug/release. This
  is 40 test executions, not 40 distinct tests.

The measured sampler's SHA-256 is
`a91a8b3b2a40d1992f8bfe1cc7feae34171bccb1a930daf0b88a0091f6a65ccc`.
The downloaded artifact is `12793522961`, named `video-color-sampling-native`;
its ZIP SHA-256 is
`0334bedee97fb8c379a0aba855f9b49f2febf351236cf38df4999512f6a8e92a`.
The following evidence-only commit preserves the measured production code.

## Limits

The production sampler accepts at most four frames per second when adaptive
color sampling is enabled. This is a small absolute component improvement.
These warmed synthetic-buffer measurements do not establish lower whole-player
CPU usage, power consumption, dropped frames, GPU cost, or interactive latency.
Process CPU time was not recorded by this campaign.

The timed cases exercise supported raw `sample()` calls. They do not measure
unsupported-format rejection, already-throttled calls, or stateful smoothing
and publication costs. Temporal correctness is covered by exact output traces
and regression tests. The successful run compiles and tests the native component;
it does not constitute full-application compilation or live playback/UI
qualification. Any broader CI result must be reported separately.

The concurrent experiments use different harness/module boundaries and output
consumption. Their percentages cannot rank the production implementations
against each other. This report supports this candidate over the pinned main
baseline only.

## Durable evidence and reproduction

The [retained evidence](evidence/independent-563b8/) includes the environment and
source manifest, all raw timing/calibration observations, AB/BA schedule, command
receipts, exact verification traces, four native test logs, and the independent
audit. `verification.json.gz` decompresses to the original `verification.json`
bytes. The original workflow artifact additionally contains all source snapshots
and individual command logs; the sources remain reproducible from the recorded
Git commits after the hosted artifact expires.

Run the committed benchmark following its [README](README.md) and the repository's
Kyoto build-coordination instructions. Use a new output directory and preserve
the host/compiler and exact compared revisions when repeating the experiment.
