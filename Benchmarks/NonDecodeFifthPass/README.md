# State publication / fifth-pass experiments

Runs actual selected IlliquidCore values, State and ViewStore with real Foundation and Observation. No GUI, decoder, filesystem workload, or framework doubles. See `Documentation/NONDECODING_PERFORMANCE_FIFTH_PASS.md` for interpretation and limits.

## Requirements and commands

Python 3.10+ and a Swift 6 toolchain. The execution environment was Swift 6.2.1, Linux/glibc. All data is synthetic. No network fetch, application launch, user preference changes, or global configuration changes occur. Use a complete checkout with the cumulative changes, or run within the selected `candidate/` tree which carries the needed earlier benchmark fixtures.

```sh
python3 Benchmarks/NonDecodeFifthPass/run.py --tests-only --output /tmp/state-release
python3 Benchmarks/NonDecodeFifthPass/run.py --tests-only --configuration debug --output /tmp/state-debug
python3 Benchmarks/NonDecodeFifthPass/run.py --variants v4 v5 --repeats 9 --output /tmp/state-timing
python3 Benchmarks/NonDecodeFifthPass/validate-orders.py /tmp/state-timing

# Linux/glibc only; allocation REQUEST traffic, not heap/RSS/footprint.
python3 Benchmarks/NonDecodeFifthPass/run.py --allocations --variants v4 batched v5 \
  --repeats 3 --workloads position scalar_same chapter_index tracks_same tracks_changed diagnostic diagnostic_disconnected \
  --output /tmp/state-allocations
python3 Benchmarks/NonDecodeFifthPass/validate-orders.py /tmp/state-allocations
```

Output directories must be new or empty. The runner builds a separate actual core module and client, records commands/errors/source and binary hashes, checks final state, and writes every completed row before summaries. It does not run the full SwiftPM package. A failed run remains evidence, not passing data; output is never overwritten. The `validate-orders.py` step is mandatory when accepting timing data. It verifies actual row order/uniqueness and has regression checks for the old order bug.

On this supplied Linux toolchain, dynamic Observation linkage had a hidden `swift::threading::fatal` resolution error. `-static-stdlib` uses the matching installed static Swift runtime; no runtime shim is substituted. The driver applies this equally on Linux and omits it on macOS. Original files are checked against Git blob hashes before compiling. `ShellEnums.swift` contains exact supporting declarations from files with unrelated geometry/playlist dependencies. Supporting v2 fixtures are reused unchanged.

The tests compile 15 scenario bodies shared with the native XCTest wrappers. Standalone execution does not constitute XCTest discovery or full app tests. Final expected results: 15 passing scenarios/987 assertions; differential 20,000 operations/60,000 comparisons, baseline 23,040 and candidate 15,300 callbacks; candidate diagnosis one coherent chapter publication, one capped diagnostic/max 100, zero equal-volume callbacks, zero no-op-adjustment source observations.

## Variants and evidence

- `v4`: exact original state file, unchanged by passes 1–4.
- `batch`: six synchronous batches only, a minimal ablation.
- `guarded`: rejected early trial with extra array guards and runtime-gated probes.
- `batched`: narrowed candidate before capacity-aware track partitioning.
- `v5`: final delivered production state.

`evidence/final-timing` (288 rows) and `evidence/final-allocations` (81 rows) are the corrected order-balanced primary cohorts. Two-variant initial runs mistakenly canceled rotation with reversal and always ran baseline first. Everything under `exploratory-*` is retained but excluded from final headline values. Earlier `v5` labels name different frozen candidates; see `execution-notes.json`. The first trial's original assertion-only helper bytes were not preserved; its production and timing harness were. Final cohorts match delivered production/harness/test hashes.

Warmup 200 calls; all constructors and final serialization/checks outside timing. Measurements are process-mean synchronous service costs, not individual UI p95/p99 or input-to-photon. Track fixtures include eight and 128 tracks; chapter control includes 10,000 entries differing only at the last entry. Source near-front selected IDs are not exhaustive position scenarios. Process CPU and min/max are retained. Allocator runs are separate from unmetered timing.

## Native qualification and diagnostics

In the full macOS repository with its pinned toolchain/dependencies:

```sh
swift test -c release --filter 'PlaybackStatePublicationTests|PlaybackStateTests'
# Then the full app/core/native suites, architecture check and release build.
```

The new source/XCTest wrappers typecheck on Linux. macOS SDK build and native execution are outstanding. Use matched release bundles and native SwiftUI/File Activity/Allocations traces, with actual event frequency. Do not interpret two-to-one snapshot callbacks as half as many render passes.

`PlaybackStatePublish` requires compilation with `-DILLIQUID_STATE_SIGNPOSTS` (SwiftPM: `-Xswiftc -DILLIQUID_STATE_SIGNPOSTS`) and the existing benchmark bundle/runtime guards: `com.example.IlliquidBenchmark`, `ILLIQUID_ENABLE_BENCHMARK_OVERRIDES=1`, `ILLIQUID_BENCHMARK_NONDECODE=1`. Without the compile-time define, no new state-publication probe is inserted. Use separate instrumented diagnostics, not that build for headline CPU/footprint comparisons. No media paths, retained logs, or timers are added.
