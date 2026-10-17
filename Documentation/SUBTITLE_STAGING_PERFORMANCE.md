# Subtitle staging storage reuse

## Finding and change

Repeated CPU preparation of small subtitles became unnecessarily expensive after
a large subtitle frame had grown the reusable staging buffers. The packer kept
clearing the entire historical allocation for every changed frame. Tracking the
previous active prefix of each rotating buffer removes that repeated work while
preserving the complete returned frame, including its zero-filled tail.

The production change is confined to `ASSSubtitleFramePacker` and its existing
clear-byte diagnostic in
[`MetalASSSubtitleCompositor.swift`](../Sources/IlliquidNativePlayback/Subtitles/MetalASSSubtitleCompositor.swift).
The baseline is `main` at `8c3cc3d4008d5d1b8d436bcf2d51d891382b6548`.
The measured candidate compositor SHA-256 is
`42ec2d4371fd595d442f7a2d109ef36c10824b478dc87728fbb89ce6bee5e7f7`.

The Apple Silicon macOS measurements show the largest benefit after a
large-to-small transition: a 16 MiB R8 slot preparing a 64 KiB texture fell from
298.337 to 2.679 microseconds per preparation. The same workload fell from
470.717 to 2.419 microseconds on Linux. These are synthetic, reproducible
workloads; the frequency of this state in users' media has not been measured.

## Why this path matters

`SubtitlePipeline.consumeMetalRequest` calls the packer after
`delivery.requiresPresentation` accepts a changed frame or a required
re-presentation. An unchanged subtitle observation skips this preparation.
The packer supports R8 masks from libass, premultiplied BGRA bitmap atlases, and
the CPU BGRA compatibility strategy. Main-window and PiP rendering consume the
prepared texture using its current dimensions and row stride.

Both staging pools have two rotating `Data` slots. Their sizes grow to retain the
largest frame seen for that pool. For example, three large R8 masks can produce
a 16 MiB atlas; the following caption can use only 64 KiB. The old helper still
called `resetBytes` across 16 MiB every time that small caption was prepared.
The existing `atlasClearBytes` counter reported only the 64 KiB upload footprint,
concealing the larger reset request.

## Preserved frame contract

Each slot now records its previous active byte count. Before reuse, the packer
clears the larger of the current and previous active prefixes. Bytes beyond that
prefix are already zero because the preceding frame could not write there.
On growth, `Data(count:)` initializes the entire new allocation. Source
retirement resets the two pools and their corresponding prefix histories.

The first smaller frame in each formerly large slot still clears the large
prefix once. Only subsequent smaller frames avoid the unnecessary tail clear.
Tracking is per slot and uses byte counts, which covers R8-to-bitmap changes in
the shared atlas pool. Validation or memory-reservation failures occur before
the prefix history changes.

The returned `Data.count`, full pixel contents, packing order, padding,
compositing, buffer rotation, and memory reservations retain their existing
semantics. The mutex and `Data` snapshot ownership also retain their behavior.
`atlasClearBytes` now reports logical bytes initialized on growth or explicitly
reset on reuse; `atlasReallocated` keeps its existing high-water-growth meaning.
Logical initialization/reset bytes do not measure physical DRAM traffic or
additional copy-on-write traffic.

## Measurement method

[`Benchmarks/SubtitleStaging/run.py`](../Benchmarks/SubtitleStaging/run.py) extracts
complete production declarations at checked, unique boundaries. It compiles the
actual packer, rendered-region type, and memory budget. There is no translated
packer implementation or simulated renderer. Foundation provides geometry types
on Linux; macOS additionally imports their original CoreGraphics module.

The pinned baseline and candidate are separate executables, built with Swift 6
language mode, `-O`, and whole-module optimization. The recorded compilers are
Apple Swift 6.3.3 on macOS and Swift 6.3.2 on Linux. The identical driver alternates
prebuilt input pixel variants of equal geometry. A production
`SubtitleMemoryBudget` remains alive throughout each run. The production,
generated-source, driver, and runner hashes match between platforms.

There are 12 workloads, each with 10 fresh-process baseline/candidate pairs:
five baseline-first and five candidate-first, for **240 timing observations per
platform**, or 480 in total.
Every process fills both slots, then performs at least eight warm-up preparations
before timing. Initial allocations and the first per-slot cleanup are excluded
from the steady-state table and captured separately in the transition evidence.
The ordinary workloads retain one prior frame; two additional workloads retain
three frames to exercise reuse while both slots remain externally shared.

Each observation reports average time per preparation over its timed batch. The
table reports the median of those ten batch averages, **not a per-frame latency
percentile**. Full ranges, raw durations, iterations, order, checksums, storage
and budget receipts, compiler settings, and source/executable hashes are in
[`RESULTS-macos.json`](../Benchmarks/SubtitleStaging/RESULTS-macos.json) and
[`RESULTS-linux.json`](../Benchmarks/SubtitleStaging/RESULTS-linux.json).

## macOS results

Measured on an Apple Silicon GitHub Actions runner using macOS 26.6.2 and Apple
Swift 6.3.3, targeting `arm64-apple-macosx26.0`. Times are microseconds per changed
subtitle preparation, including the real memory-budget resize check.

| Workload | Historical slot → active bytes | Baseline median | Candidate median | Change |
| --- | --- | ---: | ---: | ---: |
| R8 medium → small | 2 MiB → 64 KiB | 21.726 | 2.669 | -87.7% |
| R8 large → small | 16 MiB → 64 KiB | 298.337 | 2.679 | -99.1% |
| Bitmap atlas large → small | 16 MiB → 512 KiB | 284.088 | 14.436 | -94.9% |
| CPU BGRA canvas large → small | 1920×1080 → 640×360 | 227.968 | 92.858 | -59.3% |
| R8 small, stable size | 64 KiB → 64 KiB | 2.633 | 2.643 | +0.4% |
| R8 large, stable size | 16 MiB → 16 MiB | 1039.616 | 1017.036 | -2.2% |
| Bitmap atlas small, stable size | 512 KiB → 512 KiB | 13.844 | 13.963 | +0.9% |
| Bitmap atlas large, stable size | 16 MiB → 16 MiB | 969.662 | 977.497 | +0.8% |
| CPU BGRA small, stable size | 640×360 → 640×360 | 90.810 | 90.869 | +0.1% |
| CPU BGRA large, stable size | 1920×1080 → 1920×1080 | 210.483 | 210.724 | +0.1% |
| R8 large → small, three held frames | 16 MiB → 64 KiB | 2146.610 | 16.977 | -99.2% |
| Bitmap large → small, three held frames | 16 MiB → 512 KiB | 2221.679 | 82.935 | -96.3% |

All three small stable-size controls changed by less than 1% in their medians;
the stable-size ranges overlap. Large-to-small timings separate substantially
and reproduce the intended benefit on the application's target platform.

The three-held-frame workloads show much lower candidate times on macOS than on
Linux. These workloads preserve snapshots beyond the two-slot pool and exercise
`Data`'s value semantics. Physical copying, allocation behavior, and DRAM traffic
were not instrumented, so the platform difference does not establish a specific
Foundation or virtual-memory mechanism.

The benchmark and debug/release component tests passed in
[workflow run 39043712484](https://github.com/Jagalite/illiquid/actions/runs/39043712484).
[`VALIDATION-macos.json`](../Benchmarks/SubtitleStaging/VALIDATION-macos.json)
records the tested implementation commit, downloaded artifact checksum, source
identity checks, paired-output checks, and native test results. The committed
raw results preserve the evidence after the workflow artifact expires.

## Linux results

Measured on the shared Linux x86_64 execution host. Times are microseconds per
changed subtitle preparation, including the real memory-budget resize check.

| Workload | Historical slot → active bytes | Baseline median | Candidate median | Change |
| --- | --- | ---: | ---: | ---: |
| R8 medium → small | 2 MiB → 64 KiB | 26.104 | 2.558 | -90.2% |
| R8 large → small | 16 MiB → 64 KiB | 470.717 | 2.419 | -99.5% |
| Bitmap atlas large → small | 16 MiB → 512 KiB | 515.156 | 16.233 | -96.8% |
| CPU BGRA canvas large → small | 1920×1080 → 640×360 | 309.710 | 156.308 | -49.5% |
| R8 small, stable size | 64 KiB → 64 KiB | 2.669 | 2.674 | +0.2% |
| R8 large, stable size | 16 MiB → 16 MiB | 1297.190 | 1153.863 | -11.0% |
| Bitmap atlas small, stable size | 512 KiB → 512 KiB | 16.044 | 16.334 | +1.8% |
| Bitmap atlas large, stable size | 16 MiB → 16 MiB | 1523.043 | 1537.822 | +1.0% |
| CPU BGRA small, stable size | 640×360 → 640×360 | 135.436 | 140.781 | +3.9% |
| CPU BGRA large, stable size | 1920×1080 → 1920×1080 | 309.149 | 315.848 | +2.2% |
| R8 large → small, three held frames | 16 MiB → 64 KiB | 1977.491 | 1336.103 | -32.4% |
| Bitmap large → small, three held frames | 16 MiB → 512 KiB | 1940.532 | 1252.618 | -35.4% |

Stable-size control ranges overlap substantially on this shared host. Their
median changes do not establish a general stable-size improvement or regression.
The large-to-small cases show the intended change in cleared footprint and a
much larger timing separation. With three held snapshots, the Linux candidate
still takes approximately 1.25–1.34 milliseconds per preparation. Those costs
are platform-dependent; the macOS results above are materially lower.

The large R8 and bitmap workloads retain the same 32 MiB across their two staging
slots before and after the change. All 120 paired observations on each platform
agree on active bytes, retained staging bytes, budget reservations, and output
checksums. Those logical staging counts exclude independently retained snapshot
copies and are
not process-memory measurements.

[`TRANSITIONS-linux.json`](../Benchmarks/SubtitleStaging/TRANSITIONS-linux.json)
records the first six smaller preparations. The candidate correctly reports two
16 MiB cleanups before dropping to 64 KiB R8 or 512 KiB bitmap clears. The old
counter reports the small active size throughout; its actual reset range follows
the baseline helper and high-water `Data.count`, not that erroneous counter.

## Correctness and review

[`SubtitleStagingReuseTests.swift`](../Tests/IlliquidNativePlaybackTests/SubtitleStagingReuseTests.swift)
contains six test functions with ten parameter cases. Debug and optimized
component builds pass on both Linux and macOS. The independent oracle compares
each reused frame's entire `Data` with a freshly prepared frame extended with
zeros to the historical size.
Coverage includes both slots, retained snapshots, source strides, padding,
mixed R8/bitmap formats, BGRA clipping/overlap/order, empty and invalid inputs,
failed memory reservations followed by recovery, and retirement of both pools.

The unchanged baseline passes all five pixel/snapshot correctness functions.
Only the clear-metric test fails, with four expected diagnostic assertions. This
is a performance and telemetry correction; the tests do not claim a prior pixel
corruption bug. Root and independent review runs used the same final production
and test hashes; receipts and test logs are included beside the benchmark.

Before timing, both executables produce matching receipts for 24 complete frame
buffers, geometry, quads, and every metric except the intentionally corrected
clear counter. Each verifier also makes 69 checks against independent copied
byte arrays from held snapshots. These full-buffer hashes complement the exact
byte comparisons in the regression suite.

Independent reviews examined the slot invariant, all write bounds, failure
ordering, upload consumers, snapshot ownership, benchmark extraction, process
order, compiler settings, and CI. Review caught and fixed the standalone
macOS deployment target, explicit Swift 6 mode, and workload catalogue before
the final measurements.

## Native qualification and scope

The dedicated
[`subtitle-staging-performance.yml`](../.github/workflows/subtitle-staging-performance.yml)
workflow passed both jobs in
[run 39043712484](https://github.com/Jagalite/illiquid/actions/runs/39043712484)
for implementation commit `2b889057daf791ee5d749963a374ccd04d043309`. The
component job passed macOS debug/release regressions and the paired benchmark.
The native job built the full application dependency graph using the pinned
native SDK and passed **51 tests in three suites**: `SubtitleStagingReuseTests`,
`MetalASSSubtitleCompositorTests`, and `PiPSubtitlePipelineTests`.

The native tests exercised actual Metal composition and PiP consumers, including
SDR and HDR paths. Some media-fixture-dependent tests return early when their
fixture is unavailable; the suite result does not certify every real-media
scenario or interactive GUI behavior. The contiguous native test-output excerpt
is preserved in
[`TESTS-native-macos.log`](../Benchmarks/SubtitleStaging/TESTS-native-macos.log).
The subsequent evidence-only commit leaves the production, test, and benchmark
code exactly as tested.

These measurements establish CPU staging savings for changed subtitle frames
following larger allocations. Whole-player CPU, visible frame pacing, battery
use, prevalence in real media, and physical memory changes require application
profiling. Retained storage, texture uploads, and GPU work are unchanged by this
optimization. The large synthetic workloads demonstrate the mechanism rather
than the performance of an ordinary static subtitle track.

## Other candidates considered

The audit also found repeated peak scans in software-planar ownership
bookkeeping. A separate exploratory lifecycle measurement suggested roughly
2.3 microseconds saved per software frame at the 16-buffer cap by skipping
redundant phase-transition scans. That much smaller absolute saving was deferred
to keep this change focused. The subtitle memory budget's repeated reservation
scans are another potential follow-up; they remain in the measured path here.

## Reproduction

```sh
# From a checkout containing the pinned baseline commit, with Swift on PATH:
python3 Benchmarks/SubtitleStaging/run.py test
python3 Benchmarks/SubtitleStaging/run.py test --configuration release
python3 Benchmarks/SubtitleStaging/run.py benchmark --output /tmp/subtitle-staging-run

# Original source + current tests: four expected clear-counter assertions fail.
python3 Benchmarks/SubtitleStaging/run.py test \
  --source-ref 8c3cc3d4008d5d1b8d436bcf2d51d891382b6548

# Inspect the one-time cleanup separately after the benchmark has built binaries:
/tmp/subtitle-staging-run/candidate/subtitle-staging transition r8-large-to-small 1

# Full native package, with the repository's pinned SDK prerequisites installed:
swift test --force-resolved-versions --filter \
  'SubtitleStagingReuseTests|MetalASSSubtitleCompositorTests|PiPSubtitlePipelineTests'
```

Each runner invocation uses a new output directory and records the exact source
and toolchain receipts. Timing has no CI pass/fail threshold; correctness and
baseline/candidate output equality are the gates.
