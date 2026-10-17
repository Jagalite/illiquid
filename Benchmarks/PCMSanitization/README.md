# PCM sanitation benchmark

This experiment measures the actual `sanitizeInterleavedFloatPCM` function from the pinned baseline and the working tree. It checks exact output bytes and replacement counts before comparing optimized Swift executables. The sample data are synthetic PCM, not decoded media.

Baseline: `8c3cc3d4008d5d1b8d436bcf2d51d891382b6548`.

## Reproduce

Requirements: Python 3 and Swift with Swift Testing; the Linux research toolchain is Swift 6.3.2. The runner uses Python's standard library and generates a Foundation-only Swift package. It does not download dependencies or edit the repository.

```sh
python3 Benchmarks/PCMSanitization/run.py \
  --mode verify --output /tmp/pcm-verification

python3 Benchmarks/PCMSanitization/run.py \
  --mode test --test-variant both --test-configuration both \
  --output /tmp/pcm-tests

python3 Benchmarks/PCMSanitization/run.py \
  --mode test --test-variant candidate --test-configuration release \
  --sanitize address --output /tmp/pcm-address-sanitizer

python3 Benchmarks/PCMSanitization/run.py \
  --mode benchmark --pairs 6 --target-ms 80 \
  --output /tmp/pcm-benchmark
```

The runner finds `swiftc` on `PATH`, or accepts `--swiftc /path/to/swiftc`. Set any runtime-library paths required by that toolchain in the calling environment. Compiler caches are written inside the output directory. A shallow checkout needs the pinned commit fetched; alternatively, `--baseline-dir /path/to/original/tree` supplies baseline sources with recorded content hashes.

Formal runs require an even number of pairs of at least six. Run without competing compilations or benchmarks. On Linux, select an allowed CPU with `os.sched_getaffinity(0)` and pin the runner and its child processes using `taskset -c CPU ...`; the report records the resulting affinity. An exploratory run may use `--exploratory --pairs 2 --target-ms 15`. `--case` selects an exact case name and can be repeated; `--case-file` accepts a JSON array of names. The default retains every control case.

`--mode all` performs verification, the requested test configurations, and then timing. `--sanitize address` instruments test builds only; benchmark executables remain ordinary optimized builds. `--reuse-build` accepts previous executables only when the compiler, runner, harness, source and binary fingerprints still match.

## Workloads

The matrix contains 55 cases. Large buffers represent 1,024 frames with 1, 2, 6 or 8 channels, plus 4,096 frames with 8 channels. Mono is helper coverage; the native decoder outputs 2, 6 or 8 channels. Small buffers contain 0, 1, 7, 8 or 9 complete samples, with 0–3 trailing bytes across the input variants. Each case rotates through sixteen variants. That fixed sixteen-buffer pool defines synthetic cache conditions rather than reproducing the decoder's buffer lifecycle.

| Family | Contents and measured operation |
| --- | --- |
| `healthy_sine` | Finite sine samples interspersed with positive and negative zero; sanitize uniquely owned buffers. |
| `silence` | Positive and negative zero; sanitize uniquely owned buffers. |
| `sparse_invalid` | Sparse NaN, infinity and subnormal values, including a dirty final sample; sanitize and restore the dirty words. |
| `dense_invalid` | Approximately 75% non-finite values with varied signs and NaN payloads; sanitize and restore. |
| `subnormals` | Subnormal bit patterns of both signs; sanitize and restore. |
| `shared_healthy` | Healthy samples with another retained `Data` owner; include the intentional copy-on-write operation. |
| `sparse_restore_control`, `dense_restore_control`, `subnormal_restore_control` | Perform only the corresponding restoration stores and common result bookkeeping. |
| `tiny_tail` | Empty, short and vector-boundary inputs with dirty samples and incomplete final bytes; sanitize and restore. |
| `tiny_restore_control` | Restoration/bookkeeping control for the corresponding short input. |

Every unique slot is independently allocated with `Data(count:)` and populated from raw `UInt32` words. The timed sanitizer receives `&pool.buffers[index]` directly. Copying a fixture to a local `Data` variable before sanitizing would accidentally include copy-on-write; only `shared_healthy` deliberately does that.

Dirty fixtures are restored after **every** sanitizer invocation, including warm-up. Restoration writes the original raw words, so NaN payloads and subnormal bits do not pass through floating-point conversion. Each timed case separately accumulates its actual non-finite and subnormal replacement totals and checks them against the fixture-derived totals after the timer stops. A fixture that becomes permanently clean after its first pass fails these checks.

Dirty-case timings are explicitly **sanitize plus restoration**. Restore controls make that overhead visible. The reported reductions compare the complete named operations; they do not subtract medians to manufacture sanitizer-only values. Healthy and silence cases do not need restoration. Every iteration includes common dispatch/checksum bookkeeping, which is proportionally significant for the tiny controls.

## Source and optimizer boundaries

The runner reads `Sources/IlliquidNativePlayback/Media/AudioDecoder.swift` from the baseline commit and the working tree. It copies the complete balanced `AudioSampleSanitizationResult` declaration and `sanitizeInterleavedFloatPCM` function, retaining `@discardableResult`, and adds only `import Foundation` to the generated source. No FFmpeg, CoreMedia or audio-device types are mocked.

Both versions compile with `-O -whole-module-optimization -swift-version 6 -parse-as-library -enable-testing`. The sanitizer is a separate optimized `IlliquidNativePlayback` object and Swift module; the harness uses `@testable import` to call its actual internal API. This boundary prevents the harness optimizer from deleting sanitation stores that a later restoration overwrites. The evaluator and restoration helpers are also non-inlined.

This is a component call-boundary measurement. The production compiler may inline this helper into a decoder path, and the benchmark excludes PCM allocation by the decoder, decoding, resampling, audio-device I/O and playback scheduling. Copy-on-write timing is an explicit separate workload. No whole-player CPU, memory, energy or latency reduction is established by this harness.

The focused tests are copied verbatim from `Tests/IlliquidNativePlaybackTests/AudioSampleSanitizationTests.swift` into a Foundation-only package with the real module name. The package declares macOS 26, matching the application, and also runs this pure component on Linux. AddressSanitizer qualification uses the same extracted source and focused tests. The generated package selects Swift Testing explicitly and disables the unused XCTest runner; it refuses a test file importing XCTest rather than silently skipping those tests. This also avoids the empty Linux XCTest runner's framework allocation leak while leaving AddressSanitizer's leak detection enabled.

## Equality, timing and evidence

Before calibration, both optimized executables sanitize every variant. They compare replacement counts with fixture-derived counts, verify that restoration recovers every original byte, and check that sanitizing a shared copy preserves its retained owner. The Python runner then compares the complete baseline and candidate output records, including all bytes of every resulting buffer. The default matrix covers 880 input variants and approximately 28.9 MB of sanitized output, counting repeated fixture families. Full verification records are retained as compressed JSON.

Calibration chooses iterations for approximately the requested baseline wall time and rounds to complete sixteen-variant cycles. Those iteration counts stay equal between baseline and candidate. Each pair launches two fresh processes, alternating AB and BA order. Case traversal reverses on alternating pairs but is identical within a pair. Every case receives 64 warm-up iterations immediately before its timed loop.

Each measurement records both monotonic wall time and process CPU time. The summary reports medians and the median of per-pair candidate/baseline ratios. Percent changes therefore need not equal the ratio of the separately reported median times. All slower and unchanged controls remain in the raw data and summary.

Output files include:

- `report.json`: environment, affinity, commands, source/build receipt, test instrumentation, verification and timing summaries.
- `build-receipt.json`: original source, extracted declaration, generated source, harness, runner, compiler and executable hashes.
- `runner.snapshot.py`: exact runner bytes captured at the beginning of the invocation.
- `verification-baseline.json.gz` and `verification-candidate.json.gz`: complete original/sanitized byte records and counts.
- `calibration.json`, `iterations.json` and `cases.json`: calibration and frozen work per case.
- `measurements.jsonl`: every wall/CPU reading, iteration count, checksum, expected/actual replacement count, fixture output hash, pair order, process position and case traversal.
- `summary.json`: all per-case median readings and paired ratios.
- `tests-<variant>-<configuration>.log`: focused test output.
- Exact generated Swift source, modules, objects, executables and build logs in the relevant output subdirectories.

The receipts identify the actual source bytes used; an edit after a run requires new qualification. Native macOS integration and a running-player measurement remain separate evidence.
