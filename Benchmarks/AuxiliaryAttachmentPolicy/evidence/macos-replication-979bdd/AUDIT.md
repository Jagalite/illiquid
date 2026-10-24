# Independent native replication audit

The archived evidence is internally consistent and source-pinned. It supports fewer owned font bytes and lower live malloc accounting, while reporting worse retained resident memory and physical footprint in the 16 MiB and 64 MiB auxiliary cases. It does not support a general RAM or speed improvement claim.

Baseline `6f70cd2446fc6ef38d4e5a0fbf96f91b2234e635`; candidate `979bdd34a93af1c564d505b1b6a4f6b12de27379`. [Native job](https://github.com/Jagalite/illiquid/actions/runs/40101300598/job/120893823744). The candidate uses a Boolean policy; this evidence does not qualify PR #101's distinct enum-policy head.

The auditor reconstructed all 228 process observations, 114 paired comparisons in 19 scenarios, 396 reader receipts and 56,232 packet receipts. All persisted summary fields agree (floating-point tolerance 1e-12). 10,463 checks passed.

Positive reductions below mean baseline minus candidate. Negative reductions mean the candidate consumed more. Every memory value uses MiB (1,048,576 bytes). Paired medians are computed from six paired observations; they may differ from the difference between the two marginal medians.

## Retained memory: every cohort

RSS and physical-footprint samples are taken with all input owners alive, before parity hashing or packet reads. Heap is malloc-zone size-in-use accounting; it is not resident physical memory.

| Fixture | Reader layout | Copied bytes B → C | Heap B → C | Heap paired reduction | RSS B → C | RSS paired reduction [min, max] | Footprint B → C | Footprint paired reduction [min, max] |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| none | direct, auxiliary-only | 0.000 → 0.000 | 0.498 → 0.498 | +0.000 | 13.211 → 13.258 | -0.055 [-0.078, +0.047] | 3.525 → 3.572 | -0.055 [-0.078, +0.047] |
| fonts-2mib | direct, auxiliary-only | 2.000 → 0.000 | 8.552 → 6.548 | +2.004 | 21.406 → 21.391 | +0.031 [-0.062, +0.125] | 11.689 → 11.720 | -0.016 [-0.109, +0.078] |
| fonts-16mib | direct, auxiliary-only | 16.000 → 0.000 | 64.498 → 48.478 | +16.020 | 61.953 → 65.836 | -3.906 [-3.984, -3.812] | 52.220 → 56.181 | -3.984 [-4.062, -3.891] |
| fonts-64mib | direct, auxiliary-only | 64.000 → 0.000 | 256.498 → 192.478 | +64.020 | 205.922 → 221.883 | -15.969 [-15.984, -15.938] | 196.267 → 212.307 | -16.047 [-16.062, -16.016] |
| unsupported-only | direct, auxiliary-only | 0.000 → 0.000 | 48.333 → 48.329 | +0.004 | 77.547 → 77.617 | -0.086 [-0.125, +0.094] | 67.798 → 67.947 | -0.164 [-0.203, +0.016] |
| mixed | direct, auxiliary-only | 2.000 → 0.000 | 56.383 → 54.379 | +2.004 | 85.742 → 85.680 | +0.070 [-0.047, +0.156] | 75.994 → 76.009 | -0.008 [-0.125, +0.078] |
| none | executor, primary-plus-one | 0.000 → 0.000 | 0.919 → 0.919 | +0.000 | 13.805 → 13.852 | -0.031 [-0.125, +0.016] | 4.087 → 4.134 | -0.031 [-0.125, +0.016] |
| fonts-2mib | executor, primary-plus-one | 4.000 → 2.000 | 17.023 → 15.023 | +2.000 | 28.125 → 28.086 | +0.008 [-0.094, +0.094] | 18.376 → 18.337 | +0.008 [-0.094, +0.094] |
| fonts-16mib | executor, primary-plus-one | 32.000 → 16.000 | 128.916 → 112.899 | +16.016 | 110.836 → 114.883 | -4.055 [-4.125, -4.016] | 101.127 → 105.166 | -4.039 [-4.125, -4.016] |
| fonts-64mib | executor, primary-plus-one | 128.000 → 64.000 | 512.916 → 448.899 | +64.016 | 398.805 → 414.883 | -16.055 [-16.125, -16.016] | 389.260 → 405.338 | -16.055 [-16.125, -16.000] |
| unsupported-only | executor, primary-plus-one | 0.000 → 0.000 | 96.586 → 96.586 | +0.000 | 126.070 → 126.172 | -0.094 [-0.203, -0.031] | 116.322 → 116.423 | -0.094 [-0.203, -0.031] |
| mixed | executor, primary-plus-one | 4.000 → 2.000 | 112.686 → 110.686 | +2.000 | 140.312 → 140.414 | -0.094 [-0.188, -0.016] | 130.580 → 130.681 | -0.094 [-0.188, -0.016] |
| none | executor, primary-plus-two | 0.000 → 0.000 | 1.335 → 1.335 | +0.000 | 14.219 → 14.273 | -0.070 [-0.125, +0.031] | 4.501 → 4.556 | -0.070 [-0.125, +0.031] |
| fonts-2mib | executor, primary-plus-two | 6.000 → 2.000 | 25.489 → 21.489 | +4.000 | 34.664 → 34.648 | +0.000 [-0.031, +0.047] | 24.931 → 24.915 | +0.000 [-0.031, +0.047] |
| fonts-16mib | executor, primary-plus-two | 48.000 → 16.000 | 193.328 → 161.295 | +32.033 | 159.516 → 163.508 | -3.992 [-4.062, -3.922] | 149.869 → 153.838 | -3.969 [-4.031, -3.906] |
| fonts-64mib | executor, primary-plus-two | 192.000 → 64.000 | 769.328 → 641.295 | +128.033 | 591.492 → 607.531 | -15.992 [-16.312, -15.969] | 582.105 → 598.120 | -15.977 [-16.062, -15.937] |
| none | direct, primary-only | 0.000 → 0.000 | 0.498 → 0.498 | +0.000 | 13.227 → 13.203 | +0.000 [-0.031, +0.062] | 3.540 → 3.517 | +0.000 [-0.031, +0.062] |
| fonts-2mib | direct, primary-only | 2.000 → 2.000 | 8.552 → 8.552 | +0.000 | 21.414 → 21.391 | +0.023 [-0.031, +0.062] | 11.697 → 11.673 | +0.023 [-0.031, +0.062] |
| fonts-16mib | direct, primary-only | 16.000 → 16.000 | 64.498 → 64.498 | +0.000 | 61.922 → 62.086 | -0.133 [-0.219, -0.047] | 52.189 → 52.353 | -0.133 [-0.219, -0.047] |

The candidate's retained RSS and footprint are higher in all six pairs in each 16 MiB and 64 MiB auxiliary cohort. The increase is approximately 4 MiB for 16 MiB of attached fonts and 16 MiB for 64 MiB. With a primary plus two auxiliary readers and 64 MiB of fonts, copied payloads fall from 192 to 64 MiB and live heap from 769.328 to 641.295 MiB, while resident memory rises from 591.492 to 607.531 MiB and footprint from 582.105 to 598.120 MiB.

## Opening time: every cohort

Times are milliseconds for opening all readers in the layout. The percentage is the median paired percentage reduction. No general speedup claim is justified; these short opens vary considerably, including controls.

| Fixture | Reader layout | Wall B → C (ms) | Wall paired reduction (ms) [min, max] | Wall paired reduction % | CPU B → C (ms) | CPU paired reduction (ms) [min, max] | CPU paired reduction % |
|---|---|---:|---:|---:|---:|---:|---:|
| none | direct, auxiliary-only | 1.420 → 1.447 | +0.012 [-0.407, +4.118] | +0.803% | 1.422 → 1.449 | +0.012 [-0.409, +2.873] | +0.776% |
| fonts-2mib | direct, auxiliary-only | 3.334 → 3.056 | +0.389 [-0.079, +1.078] | +9.579% | 3.330 → 2.925 | +0.438 [-0.111, +1.079] | +12.215% |
| fonts-16mib | direct, auxiliary-only | 11.947 → 11.749 | -0.007 [-1.070, +12.499] | +0.027% | 11.948 → 11.722 | -0.007 [-1.072, +12.349] | +0.027% |
| fonts-64mib | direct, auxiliary-only | 43.339 → 44.317 | -1.478 [-17.063, +2.322] | -3.596% | 43.334 → 44.320 | -1.487 [-17.478, +2.276] | -3.616% |
| unsupported-only | direct, auxiliary-only | 14.264 → 13.685 | +0.503 [-1.312, +21.386] | +3.432% | 14.259 → 13.646 | +0.508 [-1.313, +21.412] | +3.465% |
| mixed | direct, auxiliary-only | 15.062 → 14.933 | +1.054 [-0.291, +6.944] | +7.006% | 15.064 → 14.935 | +1.055 [-0.291, +6.923] | +7.015% |
| none | executor, primary-plus-one | 2.150 → 1.969 | +0.077 [-0.227, +0.474] | +3.695% | 2.152 → 1.970 | +0.077 [-0.226, +0.485] | +3.691% |
| fonts-2mib | executor, primary-plus-one | 5.991 → 6.768 | +0.439 [-5.636, +0.993] | +6.215% | 5.925 → 6.492 | +0.681 [-5.633, +0.928] | +10.013% |
| fonts-16mib | executor, primary-plus-one | 23.169 → 24.355 | -1.262 [-13.221, +4.913] | -5.622% | 23.171 → 24.247 | -1.268 [-11.738, +5.146] | -5.646% |
| fonts-64mib | executor, primary-plus-one | 94.468 → 91.839 | +2.629 [-11.885, +291.431] | +2.650% | 93.690 → 91.744 | +1.946 [-11.892, +287.775] | +1.989% |
| unsupported-only | executor, primary-plus-one | 28.475 → 27.187 | +0.236 [-4.167, +19.900] | +1.006% | 28.471 → 27.177 | +0.220 [-4.075, +18.561] | +0.941% |
| mixed | executor, primary-plus-one | 32.198 → 33.846 | +1.663 [-8.790, +15.367] | +6.181% | 32.200 → 33.898 | +1.646 [-8.792, +14.636] | +5.329% |
| none | executor, primary-plus-two | 2.652 → 2.718 | -0.151 [-0.768, +0.194] | -6.628% | 2.654 → 2.723 | -0.154 [-0.760, +0.190] | -6.759% |
| fonts-2mib | executor, primary-plus-two | 8.905 → 7.837 | +0.676 [-1.362, +4.523] | +9.166% | 8.907 → 7.843 | +0.677 [-1.102, +4.518] | +9.169% |
| fonts-16mib | executor, primary-plus-two | 34.058 → 45.562 | -12.036 [-57.675, +3.595] | -37.335% | 34.058 → 45.558 | -11.731 [-56.134, +3.575] | -36.389% |
| fonts-64mib | executor, primary-plus-two | 255.550 → 192.436 | +63.114 [-10.194, +575.602] | +24.611% | 224.413 → 185.236 | +39.177 [-10.448, +509.136] | +17.217% |
| none | direct, primary-only | 1.593 → 1.499 | +0.135 [-0.220, +0.562] | +7.911% | 1.590 → 1.501 | +0.134 [-0.219, +0.560] | +8.042% |
| fonts-2mib | direct, primary-only | 4.080 → 4.723 | -0.412 [-2.677, +1.913] | -12.787% | 4.081 → 4.654 | -0.346 [-2.679, +1.802] | -11.067% |
| fonts-16mib | direct, primary-only | 13.884 → 13.281 | +0.055 [-3.417, +10.530] | +0.398% | 13.813 → 13.269 | +0.055 [-2.817, +7.397] | +0.406% |

The 16 MiB primary-plus-two cohort is adverse on opening time: wall time's median paired reduction is −37.335% and CPU's is −36.389%; five of six pairs are slower. The raw pairs and extrema are preserved in audit-result.json. This timing result should not be discarded because other font sizes improve.

## After-release diagnostics

These samples follow attachment hashing, metadata snapshots, codec-private data copies, packet reads, seeks, and receipt construction. They are not a controlled release-only measurement. They neither explain the retained RSS regression nor establish deallocation-related physical-memory savings. Every weak reader probe was nil. After-release live heap is below 1 MiB in every observation, consistent with the observed reader lifetime assertions; physical memory includes retained allocator state and the intervening workload.

| Fixture | Reader layout | Heap B → C | RSS B → C | RSS paired reduction | Footprint B → C | Footprint paired reduction |
|---|---|---:|---:|---:|---:|---:|
| none | direct, auxiliary-only | 0.328 → 0.328 | 15.695 → 15.852 | -0.164 | 4.494 → 4.642 | -0.156 |
| fonts-2mib | direct, auxiliary-only | 0.331 → 0.329 | 25.844 → 23.984 | +1.867 | 14.611 → 12.775 | +1.852 |
| fonts-16mib | direct, auxiliary-only | 0.338 → 0.335 | 80.305 → 68.273 | +12.023 | 69.064 → 57.088 | +11.977 |
| fonts-64mib | direct, auxiliary-only | 0.338 → 0.335 | 272.289 → 224.320 | +47.984 | 261.151 → 213.213 | +47.945 |
| unsupported-only | direct, auxiliary-only | 0.330 → 0.330 | 79.906 → 80.039 | -0.156 | 68.650 → 68.830 | -0.195 |
| mixed | direct, auxiliary-only | 0.333 → 0.331 | 90.086 → 88.094 | +1.984 | 78.845 → 76.908 | +1.930 |
| none | executor, primary-plus-one | 0.506 → 0.507 | 16.492 → 16.609 | -0.117 | 5.244 → 5.353 | -0.117 |
| fonts-2mib | executor, primary-plus-one | 0.513 → 0.513 | 34.789 → 32.953 | +1.812 | 23.541 → 21.697 | +1.813 |
| fonts-16mib | executor, primary-plus-one | 0.529 → 0.526 | 145.461 → 133.547 | +11.883 | 134.244 → 122.307 | +11.891 |
| fonts-64mib | executor, primary-plus-one | 0.529 → 0.526 | 529.398 → 481.539 | +47.898 | 518.370 → 470.471 | +47.906 |
| unsupported-only | executor, primary-plus-one | 0.512 → 0.512 | 128.641 → 128.781 | -0.117 | 117.377 → 117.510 | -0.102 |
| mixed | executor, primary-plus-one | 0.517 → 0.516 | 146.922 → 145.023 | +1.891 | 135.658 → 133.767 | +1.891 |
| none | executor, primary-plus-two | 0.668 → 0.668 | 17.094 → 17.289 | -0.203 | 5.837 → 6.041 | -0.203 |
| fonts-2mib | executor, primary-plus-two | 0.678 → 0.676 | 43.508 → 39.609 | +3.906 | 32.252 → 28.361 | +3.906 |
| fonts-16mib | executor, primary-plus-two | 0.700 → 0.695 | 210.336 → 182.281 | +28.023 | 199.166 → 171.096 | +28.047 |
| fonts-64mib | executor, primary-plus-two | 0.700 → 0.695 | 786.273 → 674.297 | +112.008 | 775.386 → 663.362 | +112.055 |
| none | direct, primary-only | 0.328 → 0.328 | 15.672 → 15.789 | -0.117 | 4.462 → 4.580 | -0.125 |
| fonts-2mib | direct, primary-only | 0.331 → 0.331 | 25.859 → 25.984 | -0.117 | 14.642 → 14.759 | -0.117 |
| fonts-16mib | direct, primary-only | 0.338 → 0.338 | 80.289 → 80.469 | -0.133 | 69.041 → 69.228 | -0.148 |

## Test evidence and skipped coverage

### Debug

`✔ Test run with 83 tests in 10 suites passed after 8.988 seconds.`

The log contains **73 passing test functions and 10 explicitly skipped functions**, with two skipped suites. The new auxiliary suite executed 20 cases: three parameterized functions with six fixtures each, plus metadata/frame-step and thumbnail-pixel parity tests.

Log SHA-256: `872f739f162e38134094ac679e5c2d760b32a4ad96a11a4bfae60851b8d70e07`.

Skipped functions and their exact recorded reasons:

- ➜ Test demuxingPreservesStreamsAndCopiesOnlySupportedFontPayloads() skipped: "Generate the mixed Matroska attachment fixture"
- ➜ Test recordReaderParity() skipped.
- ➜ Test measureNativeRequest() skipped.
- ➜ Test acceptedTimesMatchFullFramesAndIndependentFFmpeg(filename:) skipped: "Generate Benchmarks/FrameStepTimestamps fixtures"
- ➜ Test flushDropsOldDecoderAndFilterStateBeforeRepeatedSeeks(filename:) skipped: "Generate Benchmarks/FrameStepTimestamps fixtures"
- ➜ Test seekFloorPreservesFullDecoderAdmissionAndGenerationFence(filename:) skipped: "Generate Benchmarks/FrameStepTimestamps fixtures"
- ➜ Test cancellationStopsBeforeAndDuringOutputAndFlushAllowsReuse(filename:) skipped: "Generate Benchmarks/FrameStepTimestamps fixtures"
- ➜ Test consumerErrorPropagatesWithoutBecomingDeinterlacingFallback(filename:) skipped: "Generate Benchmarks/FrameStepTimestamps fixtures"
- ➜ Test timestampDiscoveryAlsoBypassesPlanarOutputStorage() skipped: "Generate Benchmarks/FrameStepTimestamps fixtures"
- ➜ Test frameStepReaderChoosesAdjacentDisplayedTimeAtBoundariesAndBetweenFrames(filename:) skipped: "Generate Benchmarks/FrameStepTimestamps fixtures"

Skipped suites:

- ➜ Suite "Frame step performance" skipped.
- ➜ Suite "Timestamp discovery without presentation buffers" skipped: "Generate Benchmarks/FrameStepTimestamps fixtures"

### Release

`✔ Test run with 83 tests in 10 suites passed after 5.293 seconds.`

The log contains **73 passing test functions and 10 explicitly skipped functions**, with two skipped suites. The new auxiliary suite executed 20 cases: three parameterized functions with six fixtures each, plus metadata/frame-step and thumbnail-pixel parity tests.

Log SHA-256: `035ae5e89e942a61defc2933feb659635afda73a1287472df4c37df347ab0197`.

Skipped functions and their exact recorded reasons:

- ➜ Test demuxingPreservesStreamsAndCopiesOnlySupportedFontPayloads() skipped: "Generate the mixed Matroska attachment fixture"
- ➜ Test recordReaderParity() skipped.
- ➜ Test measureNativeRequest() skipped.
- ➜ Test acceptedTimesMatchFullFramesAndIndependentFFmpeg(filename:) skipped: "Generate Benchmarks/FrameStepTimestamps fixtures"
- ➜ Test flushDropsOldDecoderAndFilterStateBeforeRepeatedSeeks(filename:) skipped: "Generate Benchmarks/FrameStepTimestamps fixtures"
- ➜ Test seekFloorPreservesFullDecoderAdmissionAndGenerationFence(filename:) skipped: "Generate Benchmarks/FrameStepTimestamps fixtures"
- ➜ Test cancellationStopsBeforeAndDuringOutputAndFlushAllowsReuse(filename:) skipped: "Generate Benchmarks/FrameStepTimestamps fixtures"
- ➜ Test consumerErrorPropagatesWithoutBecomingDeinterlacingFallback(filename:) skipped: "Generate Benchmarks/FrameStepTimestamps fixtures"
- ➜ Test timestampDiscoveryAlsoBypassesPlanarOutputStorage() skipped: "Generate Benchmarks/FrameStepTimestamps fixtures"
- ➜ Test frameStepReaderChoosesAdjacentDisplayedTimeAtBoundariesAndBetweenFrames(filename:) skipped: "Generate Benchmarks/FrameStepTimestamps fixtures"

Skipped suites:

- ➜ Suite "Frame step performance" skipped.
- ➜ Suite "Timestamp discovery without presentation buffers" skipped: "Generate Benchmarks/FrameStepTimestamps fixtures"

## Provenance

- Verified 73 capsule text files byte for byte against the downloaded artifact.
- Verified 36 immutable commit files against local Git blobs, including all 31 source receipts, runner/harness/generator, workflow and new test source.
- Verified compiled full Swift copies, C module/header copies, and exact helper declaration extractions. Shared dependencies and extracted helpers are equal across variants.
- Verified 4 downloaded native executable/library hashes when the original artifact was supplied. Native binaries are unnecessary to replay the numeric audit.
- Verified all 255 recorded runner commands succeeded, with 228 matching process invocations and four identical-flag optimized compile commands. All four build logs are empty. All seven fixture generation commands succeeded.
- Verified all six fixture inventories and independently regenerated deterministic attachment payload hashes. Container, installed dependency and compiler bytes were not included in the text evidence; their recorded hashes remain receipts rather than a fresh independent rehash.
- Text capsule SHA-256: `9ded86c1add39fd2cd3cd4fe0a3f2c6f1f5db4d99d26706727542952be5d951a`.
- Compact job-log binding checked: `True`.

The machine was an Apple M1 virtual host with 7 GiB RAM, macOS 26.6.2, Swift 6.3.3 and SDK 26.5. Results are from one host/session, six pairs per cohort. They are not a confidence interval or population estimate.

## Interpretation limits

- Positive reduction means baseline minus candidate; negative values mean the candidate used more memory/time. Paired medians are not differences of marginal medians.
- Six pairs per scenario, a single native virtual host/session, alternating fixed order. Ranges are observed extrema, not confidence intervals. Opening time remains exploratory.
- Retained samples precede parity hashing and packet reads; after_release samples follow hashing, packet/seek validation and receipt allocations. After-release differences are diagnostic and cannot isolate deallocation, reclaimability or the cause of retained physical-memory regressions.
- Fixtures use deterministic arbitrary font-labeled bytes, not renderable fonts. The new suite does not establish libass or main/PiP real-font visual parity.
- All 73 passing and 10 skipped test-function outcomes are recorded for each build configuration; the footer's 83 includes the skipped functions.
- The text package records fixture container, installed FFmpeg library/header and Swift compiler hashes; those original external files were not included and are not independently rehashed by this audit. Deterministic attachment payload hashes are independently regenerated.
- The benchmark completion gate verifies parity and completeness, not a threshold requiring memory or speed improvement.
- Unchanged FFmpeg native extradata and any libass font storage are outside the removed Swift-owned copies; this is not a whole-player memory measurement.
