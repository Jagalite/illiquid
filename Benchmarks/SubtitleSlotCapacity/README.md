# Subtitle staging slot capacity

The change reduces reusable subtitle staging storage after a single large frame
by **44.44–49.80%** in the measured workloads. The latest-frame Linux cohort shows
essentially unchanged resident memory for those spike workloads. Its demonstrated
benefit is smaller logical `Data` storage and subtitle-budget reservations.
Resident-memory effects depend on page touches and snapshot copies.

This component study does not establish whole-player RAM, latency, GPU memory
or FPS improvements.

## Change and ownership contract

The packer rotates between two staging slots. Previously, preparing a small
frame in one slot grew it to the largest size previously required by either
slot. A single large caption therefore propagated its peak into both slots,
even when subsequent captions were small. The new request is
`max(activeByteCount, selectedSlot.count)`: a slot grows when its own frame
requires it. Neither slot shrinks during a subtitle source's lifetime.

The atlas pool serves both R8 masks and premultiplied bitmap BGRA. The CPU BGRA
compatibility path has a separate pool and receives the same change. Both GPU
consumers upload using texture dimensions and row stride, so they require the
active prefix, without requiring equal total `Data` lengths across slots.

The change preserves exact active pixels, padding, geometry, quads, immutable
published snapshots, and source retirement. Reuse clears the larger of the
current and previous active prefixes, leaving the remaining tail zero. Budget
reservation uses actual retained slot lengths, including a large slot reused
for a small frame. The existing `atlasReallocated` diagnostic still reports a
new pool-wide byte high-water requirement; it is not an allocation counter.
See the [production packer](../../Sources/IlliquidNativePlayback/Subtitles/MetalASSSubtitleCompositor.swift)
and [regression tests](../../Tests/IlliquidNativePlaybackTests/SubtitleStagingReuseTests.swift).

## Initial Linux results: latest frame retained

The [initial summary](evidence/linux-latest1/summary.json) contains 144 fresh
measurement processes: 12 cases, six baseline/candidate pairs per case.
Baseline and candidate order alternate AB/BA, giving three pairs in each order.
No timing observations are discarded.

Each spike is `[large, small, small, small, small, small]`. Final packer-owned
slot lengths equal the staging-budget reservation in every observation.
One MiB is 1,048,576 bytes.

| Spike workload | Baseline storage | Candidate storage | Reduction |
| --- | ---: | ---: | ---: |
| R8 atlas | 32.0000 MiB | 16.0625 MiB | 49.8047% |
| Bitmap BGRA atlas | 32.0000 MiB | 16.5000 MiB | 48.4375% |
| CPU BGRA surface | 15.8203 MiB | 8.7891 MiB | 44.4444% |

All six pairs have identical byte reductions. Whole-harness current RSS does
not fall comparably:

| Spike workload | Baseline median RSS | Candidate median RSS | Median paired RSS change |
| --- | ---: | ---: | ---: |
| R8 atlas | 44.17 MiB | 44.08 MiB | +0.035% |
| Bitmap BGRA atlas | 48.95 MiB | 48.84 MiB | −0.164% |
| CPU BGRA surface | 25.03 MiB | 24.91 MiB | −0.281% |

Paired percentages are medians of per-pair changes; ratios of displayed
medians can differ. The RSS result is consistent with
untouched zero-filled allocation tails remaining nonresident; this is an
interpretation of the allocation path and observations, not a page-level trace.
Logical `Data.count` is neither allocator capacity nor physical memory usage.

The stable-small and stable-large controls have identical final slot lengths
between variants. The delayed-large sequence `[large, small, small, large]`
puts the last large frame into the other slot; final storage likewise converges
to baseline. Its current RSS still differs. Allocation, clearing and page-touch
histories differ, but this experiment does not isolate the cause. Slot counts
and RSS are therefore reported separately.

## Retained-snapshot cohort

The [held-three summary](evidence/linux-held3/summary.json) records another 144
fresh processes, using six balanced pairs per case:

| Spike workload | Baseline median RSS | Candidate median RSS | Paired RSS change | Paired peak RSS change |
| --- | ---: | ---: | ---: | ---: |
| R8 atlas | 76.102 MiB | 44.279 MiB | −41.872% | −34.532% |
| Bitmap BGRA atlas | 80.463 MiB | 49.451 MiB | −38.511% | −32.179% |
| CPU BGRA surface | 40.008 MiB | 25.742 MiB | −35.560% | −29.684% |

Current and peak RSS are lower in all 18 spike pairs. Stable controls retain
identical slot lengths; their paired current-RSS changes range from −0.666%
to +0.211%. The logical spike reductions remain those in the first table.

The held-three condition retains the last three prepared-frame values through
subsequent preparation and the memory checkpoint. This exceeds the two reusable
slots and exercises actual `Data` copy-on-write. It uses no oracle byte arrays
inside the measured process. Application ownership review found no normal
three-generation queue per packer. These whole-harness results qualify an
ownership stress condition, not ordinary playback memory savings.

## Method and qualification

Executables compile complete production packer, region and budget declarations
through the SubtitleStaging extractor. Each cohort uses the same driver for
baseline and candidate, with release optimization and whole-module
optimization. Inputs precede measurements; no warmup hides initial allocation
or deferred growth.

Inputs reuse the earlier staging geometry:

| Path | Large input | Small input |
| --- | --- | --- |
| R8 | Three 1920×1080 regions; 16 MiB atlas | 384×64 region; 64 KiB atlas |
| Bitmap | 1920×1080 region; 16 MiB atlas | 700×96 region; 512 KiB atlas |
| CPU BGRA | Fixed glyph; 1920×1080 canvas | Same glyph; 640×360 canvas |

Each runs spike, stable-small, stable-large and delayed-large sequences, with
alternating deterministic pixel values.

Verification runs separately from measurement. It compares every active byte
against fresh production packing, hashes the complete active prefix for
baseline/candidate comparison, checks every unused tail byte is zero, and
checks three retained snapshots against independently copied byte arrays.
Geometry, quad order, upload/copy metrics, and high-water events must match.
Snapshots are checked after reuse and source retirement. Focused portable tests
also cover mixed R8/bitmap atlases, clipping, overlap, invalid input, budget
rejection and subsequent reuse. Debug and release each passed seven test
functions: 14 total cases including parameterization.

Measurement retains only the requested frame values. Per-frame wall and process
CPU intervals cover preparation and assignment of the latest frame. Held-frame
queue updates are outside those intervals. Current memory is sampled after the
sequence while inputs, packer, budget and retained frames remain alive, before
output hashing or JSON encoding. Linux uses `/proc/self/status` VmRSS and
`getrusage` peak RSS; macOS uses `TASK_VM_INFO` resident size and physical
footprint, plus peak RSS. These process counters include the Swift runtime,
source images, allocator effects and harness overhead. Linux counters can differ
slightly even when sampled close together.

## Tradeoffs and limits

A large frame can move to the previously small slot, deferring an allocation
that baseline performed earlier. The delayed-large controls retain that
transition. Once both slots have seen the peak, the reusable-storage saving
disappears. There is no eviction or shrink policy in this change.

Timing is exploratory on a shared Linux host. The initial cohort contains slower
results: median paired sequence wall time increased 25.25% for R8 delayed-large,
21.37% for bitmap delayed-large, and 9.97% for BGRA stable-small. Held-three
increases include 36.44% for R8 stable-large and 126.88% for bitmap delayed-large.
Other cases improved, including unchanged-capacity controls. All observations
remain in the evidence. CPU qualification remains open; this study establishes
neither a general CPU improvement nor unchanged cold-frame latency.

The budget accounts for reusable slot lengths, not all external snapshots or
copy-on-write allocations. Smaller reservations can admit another owner whose
later presence prevents deferred slot growth. Admission still enforces the same
limits, but competing-owner acceptance need not follow the same sequence.

**Native macOS qualification is pending.** The
[workflow](../../.github/workflows/subtitle-slot-capacity.yml) repeats both
cohorts on macOS, builds the application graph, and runs staging, Metal
compositor, PiP pipeline and PiP upload-reuse tests. Linux component evidence
alone does not qualify native GPU output or physical-Mac playback.

## Provenance and reproduction

The initial [manifest](evidence/linux-latest1/manifest.json) records Linux
x86-64, kernel 6.18.55, glibc 2.39 and Swift 6.3.2. Its clean candidate was
`1eb809c3742842c00343b60594ea042cb4487f03`; baseline was
`6f70cd2446fc6ef38d4e5a0fbf96f91b2234e635`. The held-three driver was added in
`7716424b40a3aec8c9847d4653588a1d12b444cb`, without changing the measured
production implementation. Each cohort preserves source, compiler, driver and
executable hashes. Raw [observations](evidence/linux-latest1/observations.jsonl.gz),
[verification](evidence/linux-latest1/verification.json.gz) and
[commands](evidence/linux-latest1/commands.json.gz) use gzip; the
[held-three bundle](evidence/linux-held3/) uses the same filenames.
`raw-sha256.json` and `SHA256SUMS` record raw and compressed file hashes.
Independent audits of [latest-frame](evidence/linux-latest1/independent-audit.json)
and [held-three](evidence/linux-held3/independent-audit.json) each passed 144
processes, 792 timed-frame receipts, 132 verification-frame receipts and all
summary statistics. Separate
[debug](evidence/tests-debug/tests.log) and [release](evidence/tests-release/tests.log)
logs preserve test results. The original latest-frame cohort is unchanged.

From a checkout containing the baseline commit, with Python 3 and a compatible
Swift toolchain on `PATH`, use new or empty output directories:

```sh
python3 Benchmarks/SubtitleStaging/run.py test \
  --output /tmp/subtitle-slot-debug
python3 Benchmarks/SubtitleStaging/run.py test --configuration release \
  --output /tmp/subtitle-slot-release
python3 Benchmarks/SubtitleSlotCapacity/run.py --pairs 6 --held-count 1 \
  --output /tmp/subtitle-slot-latest1
python3 Benchmarks/SubtitleSlotCapacity/run.py --pairs 6 --held-count 3 \
  --output /tmp/subtitle-slot-held3
```

Use `--swift /absolute/path/to/swift` when necessary. The portable component
workflow needs no FFmpeg, libass or Metal SDK. To replay the original driver,
check out `1eb809c…` and omit `--held-count`, which was added
later. Built binaries support `list`, `verify CASE`, and `measure CASE 1|3`.

Historical compatibility also passed against `8c3cc3…`: full verification plus
two balanced pairs of `r8-large-to-small`
([receipts](evidence/historical-gate/RESULTS.json)). The gate compares active
output while independently checking zero tails and immutable snapshots; steady
measurements warm both slots. Its older baseline predates the dirty-prefix
optimization, so its timings cannot isolate this change. Historical receipts
remain unchanged.
