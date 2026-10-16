# Non-decoding follow-up: persistence and preview handoff

These are component experiments, not a complete macOS app benchmark. Baseline:
`854f8365750a0e4f046ab7015e01ca7a138ada40`. The preview comparison starts from the
previous investigation's cache candidate so its hexadecimal/admission improvements
are not credited again. Core persistence baselines are unchanged original sources.

## Reproduce

Use Python 3.10+, Swift 6, and a new empty output directory per command. The core
fixtures are original, Git-blob-verified production sources; two unrelated enums
are extracted exactly to avoid the native application dependency graph. No network
access, installed app launch, real user history, or real media is needed.

```sh
python3 Benchmarks/NonDecodeFollowup/test-core.py --output /tmp/illiquid-core-release.txt
python3 Benchmarks/NonDecodeFollowup/test-core.py --configuration debug --output /tmp/illiquid-core-debug.txt
python3 Benchmarks/NonDecodeFollowup/test-mailbox.py --output /tmp/illiquid-mailbox.txt
python3 Benchmarks/NonDecodeFollowup/test-differential.py --output /tmp/illiquid-history-differential
python3 Benchmarks/NonDecodeFollowup/run.py --phase store --repeats 7 --output /tmp/illiquid-history-timing
python3 Benchmarks/NonDecodeFollowup/run.py --phase writer --repeats 7 --output /tmp/illiquid-writer-timing
# Linux/glibc only: cumulative allocator traffic, not resident/peak/live bytes.
python3 Benchmarks/NonDecodeFollowup/run.py --phase writer --allocations --repeats 7 --output /tmp/illiquid-writer-allocations
python3 Benchmarks/NonDecodeFollowup/run-preview.py --repeats 7 --output /tmp/illiquid-preview-timing
```

Run timing drivers **serially**, not concurrently with compilation or each other.
Store timing uses the production 100 ms coalescing delay. Writer-kernel pending
mode deliberately uses a 60-second delay and explicitly flushes, isolating copying
before draining; its blocked mode gates one write callback. Store blocked mode
gates `UserDefaults.set`, after encoding. These are different workloads.
The after-each-update flush control uses five updates; burst/blocked use 100.

`StoreHarness` uses real production state, actual JSONEncoder and UserDefaults;
its defaults subclass only counts and gates calls. Seed creation is outside timing.
Callbacks/payload bytes do **not** establish physical writes or crash durability.
`flush_ns` is the final flush only. `operation_ns` also includes intermediate
flushes and is the appropriate end-to-end component comparison.

`StoreDifferential` compares 200 reload states after 10,000 mixed operations per
variant. Set ordering is normalized. The embedded history preference copy is
replaced with effective reloaded preferences because the separate preference key
has precedence in production; deferred capture can legitimately update that
obsolete duplicate later. It compares behavior, not JSON byte ordering.

## Preview harness boundary

`run-preview.py` compiles the actual cache/disk actor bodies with generated,
explicit adapters for CoreGraphics pixels, JPEG/ImageIO decode/encode, and unused
file-identity helpers. The JSON/SHA-256 digest uses real CryptoKit on macOS or
OpenSSL on Linux. Dictionary state, epoch checks, promotion, writer handoff,
FileManager operations, disk capacity/eviction and mailbox synchronization remain
the production implementation. Test extensions inject a synchronous actor stall
and inspect metadata; they are not shipped with the app.

The 100/500 ms stalls are **injected**, not measured filesystem service times.
They isolate whether a resident hit depends on an unrelated disk actor. Hot hits
are a control, and the zero-stall case measures ordinary background-to-foreground
resident promotion. Output timestamps stop at image return, not UI drawing.
Image payloads have a test header/padding, not JPEG content. Do not count this as
real macOS ImageIO/CoreGraphics, memory-pressure delivery, or UI qualification.

## Native gates

On the actual macOS app checkout, prepare its existing native SDK and run:

```sh
swift test -c release --filter 'DeferredPersistenceWriterTests|DeferredHistoryStoreTests'
swift test -c release --filter 'ThumbnailPromotionMailboxTests|QueuedThumbnailPromotionTests|NonDecodePerformanceTests|NativeThumbnailCacheTests'
# Then the complete app/core/native suites, release build, and Instruments A/B.
```

The macOS-only `QueuedThumbnailPromotionTests` use real CGImage and ImageIO;
the Linux portable runner does not execute or typecheck those framework APIs.

## Instrumentation

For a separate diagnostic capture, use bundle `com.example.IlliquidBenchmark`,
`ILLIQUID_ENABLE_BENCHMARK_OVERRIDES=1`, and `ILLIQUID_BENCHMARK_NONDECODE=1`.
Primary CPU/memory timing runs should leave the opt-in off. Intervals distinguish
history mutation (including store-lock wait), snapshot capture, encoding, defaults
set callback and final flush; resident hit, promotion reservation, disk promotion,
first inventory, and disk read. There is no per-frame timer, log array, or path
payload. Resident-byte events still exclude externally retained pixels/frameworks.

See `Documentation/NONDECODING_PERFORMANCE_FOLLOWUP.md` for measured results,
remaining risks and acceptance criteria. `evidence/` retains run manifests and raw
receipts without compiled binaries. Earlier `NonDecodePerformance/evidence` belongs
to the previous pass and must not be combined with these samples.
