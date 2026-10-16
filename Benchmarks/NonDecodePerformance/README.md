# Non-decoding performance experiments

See `../../Documentation/NONDECODING_PERFORMANCE_INVESTIGATION.md` for results,
implementation decisions, limitations and the macOS acceptance plan.

This directory is deliberately outside production SwiftPM targets. The runner
compiles selected source files directly; it never launches Illiquid, touches its
preferences/media/cache, or fetches network dependencies.

## Run from repository root

Requires Python 3.10+, Swift 6 and, for Linux allocation metering, a C compiler
and glibc. Use a **new or empty** output directory for every invocation.

```sh
python3 Benchmarks/NonDecodePerformance/run.py --tests-only --output /tmp/illiquid-logic-test
python3 Benchmarks/NonDecodePerformance/run.py --repeats 7 --output /tmp/illiquid-timings
# Linux/glibc only:
python3 Benchmarks/NonDecodePerformance/run.py --repeats 7 --allocations --output /tmp/illiquid-allocation-traffic
```

`--candidate-root` can point at a different candidate checkout. `--baseline` can
point at the bundled flat originals or the matching pinned baseline checkout.
The two baseline files must match recorded Git blob identities. These fixture
copies are **not** additional app implementations and must not be compiled into
the app. They retain the upstream project's licensing; this bundle does not
relicense Illiquid.

`PolicyHarness.swift` compiles the actual policy. Differential mode mechanically
renames the original declarations and checks ordered outputs against the candidate.
`CacheHarness.swift` exercises the real cache actor body after removing platform
imports, using `CacheStubs.swift`. The doubles do **not** validate CoreGraphics,
CryptoKit, ImageIO, filesystem operations, disk races or full macOS integration.
The `hex` measurement times formatting only. Admission timings include actor
round trips. Native `NonDecodePerformanceTests` must be run separately on macOS.

`allocmeter.c` interposes successful malloc/calloc/realloc requests. Its byte sum
is cumulative request traffic, **not** live/peak memory, RSS, physical footprint,
CGImage storage or GPU memory. Never load this instrumentation into the shipping
application. The runner supplies LD_PRELOAD only to owned benchmark subprocesses.

The evidence directory contains 196 completed observations from the investigation,
seven per group, and original command logs. Those logs preserve their historical
workspace paths. The current runner generates paths for the current checkout.
An orchestration timeout and subsequent unchanged-binary continuation are recorded
in execution-notes.txt. No partial observations or exploratory single-run timings
are mixed into the final tables.

No fixed wall-time test threshold is used on shared machines. Establish performance
budgets on controlled Apple hardware before enforcing release or CI gates.
