# Retained macOS evidence

Raw measurements, test results, command output and receipts from the successful [native geometry workflow](https://github.com/Jagalite/illiquid/actions/runs/39043693976), using Apple Swift 6.3.3 on macOS 26.6.2 ARM64 and real `SwiftUI.Path`. Six balanced AB/BA rounds produce 156 observations across 13 scenarios, with 4,000 operations per observation (400 drag corrections).

The downloaded artifact matched GitHub's SHA-256 digest. The complete extracted artifact independently passed `verify.py`: 156 measurements, four executable hashes and 15 generated-source hashes. This compact snapshot omits the generated sources and binaries; their hashes remain in `manifest.json`. Reproduce into a fresh directory to create the complete set accepted by the verifier. `provenance.json` records the tested commit/merge, workflow and artifact identities.

The native app also compiled its real dependency graph and passed 92 tests in 12 suites. `native-app-log-excerpt.txt` retains exact log lines for checkout identity, compilation, the four geometry-related suites and the final result; the complete job is linked in `provenance.json`.

The benchmark covers component calculations and path construction. It does not measure Canvas rendering, playback, whole-player resource use or interaction latency. The [research report](../../../../Documentation/ELASTIC_CONTROL_GEOMETRY_RESEARCH.md) discusses both improvements and measured control costs.
