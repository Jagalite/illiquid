# Subtitle vertex staging: portable CPU proxy

This Linux companion checks the vertex writer and measures CPU staging with
aligned raw-memory buffers. It does not use Metal, a GPU, native texture
objects, Objective-C property dispatch, or command-buffer synchronization.
Its timings cannot establish or predict the native renderer's performance.

The [native qualification](../SubtitleVertexStaging/README.md) remains the
authority for native Metal upload and rendered-output results.

## Reproduce

Requires Linux, Swift 6.1+ and Python 3.10+. Follow the repository's Kyoto
coordination instructions when that queue is available.

```sh
python3 Benchmarks/SubtitleVertexStagingPortable/run.py --tests-only \
  --output /tmp/illiquid-vertex-portable-tests
python3 Benchmarks/SubtitleVertexStagingPortable/run.py --pairs 8 --target-ms 80 \
  --output /tmp/illiquid-vertex-portable-timing
```

Use an empty output directory per attempt.

## What is reused

The wrapper imports the complete native runner after three explicit
platform adaptations: Linux eligibility, Linux hardware reporting, and the
shared-library suffix. Its paired protocol, calibration, receipt comparisons,
source extraction, baseline SHA-256 guard and statistics are reused.

The Swift driver, writer, regression tests and extracted production method
bodies retain their original statements. Import-only transformations replace
unavailable Apple modules with Foundation geometry. Named Metal stand-ins
supply the API surface needed by those declarations. Their buffer owns a
64-byte-aligned raw allocation; its pointer remains valid until deallocation.
Texture objects contain dimensions only.

Baseline and candidate modules are compiled separately from the shared driver.
Every vertex field and Float bit pattern is checked against the same oracle.
The paired measurements must match their full receipts, capacities, checksums,
iteration counts, seeds and declared workload. Padding bytes are excluded.

The tests run both upload adapters in debug and release and the unchanged
writer regression tests in debug, release and AddressSanitizer. Linux ASan
runs with only leak detection disabled, to exclude Swift Testing/runtime
lifetime allocations. This is an address/bounds check, not a leak check.

## Evidence boundaries

The native runner and driver hashes, wrapper/shim/workflow hashes, exact
transformed sources, compiler commands, binary hashes, host records,
observations and complete receipts are retained. The native runner's metadata
is explicitly relabeled as a portable CPU proxy.

The raw-memory device cannot qualify Metal allocation failure behavior,
texture/vertex descriptor integration, rendering parity, GPU synchronization,
or real resource-pool lifetime. Plain Swift texture getters can have different
optimization and dispatch costs from native Metal properties.

Fixtures, raw buffers and initial growth are outside the timed interval.
The varying-size workload measures warm buffer reuse. No array-allocation
count, whole-player performance, native Metal speedup or resident-memory
reduction is inferred from portable timings.
