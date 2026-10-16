# Fourth-pass disk-cache research

Read `Documentation/NONDECODING_PERFORMANCE_FOURTH_PASS.md`. This is a selected-source test/benchmark suite, not the macOS app build. Its cache image data consists of a synthetic header and padding, **not JPEG**. Actual actor lookup/promotion/accounting/inventory/eviction and Foundation filesystem operations execute. Only codec primitives, unused file-version probing and platform image types are adapted. Linux hashing uses OpenSSL SHA-256; no cryptographic algorithm is mocked in this suite.

## Variants

* `v3`: exact disk actor from the previously delivered v3 bundle.
* `accounting`: physical-filename accounting and preferred/fallback aliases, still inventory-first. An intermediate ablation fixture, not the final shipping source.
* `v4`: the current candidate, including exact-name lookup before inventory and failure fallback.

The active production change is in `Sources/IlliquidNativePlayback/Media/NativeThumbnailDiskCache.swift`. The eleven native counterpart tests are in `Tests/IlliquidNativePlaybackTests/ThumbnailPhysicalEntryTests.swift`. They include queued foreground protection during cold inventory, reconciliation of deferred budgets, and disabling the disk cache with reservations pending.

## Requirements and running

Python 3.10+, Swift 6.2-compatible toolchain, and OpenSSL development/linker support (`-lcrypto`) on Linux. The optional allocation interposer additionally requires glibc and Clang. Do not run multiple timing suites concurrently. All generated fixtures use disposable temporary directories and never open user media or the installed app's data.

```sh
python3 Benchmarks/NonDecodeFourthPass/build.py --output /tmp/illiquid-v4-build
python3 Benchmarks/NonDecodeFourthPass/run.py \
  --build-root /tmp/illiquid-v4-build --skip-build \
  --output /tmp/illiquid-v4-tests --tests-only
python3 Benchmarks/NonDecodeFourthPass/run.py \
  --build-root /tmp/illiquid-v4-build --skip-build \
  --output /tmp/illiquid-v4-timing --repeats 5
```

`--output` must be new/empty unless `--resume` is explicitly passed. Resumption verifies the build manifest, rejects changed binary hashes, and skips only previously completed row identities. `--cases mode:count:iterations,...` selects a subset. The supplied historical run has five repetitions of first-access/miss groups and three repetitions of the control groups; commands and raw receipts preserve that distinction. `count` is the number of unrelated files; first-hit cases add one target file. `series` uses existing files instead of adding a target.

`first-fg`, `first-bg`, and `miss` measure first actor lookup from a fresh process. `inventory` forces a complete scan. `background` intentionally retains inventory-first behavior. `warm` inventories before timing, then measures repeated disk reads (not RAM-cache hits). `series` looks up different preexisting files without forcing inventory first. `churn` inventories first and then inserts at capacity. Fixture creation, later usage and physical reconciliation are not inside the lookup interval. `usage_after_ns` and `read_plus_usage_ns` disclose the deferred inventory cost instead of implying it vanished. These intervals exclude the helper that physically verifies all remaining files.

```sh
# Optional Linux/glibc allocation traffic, NOT live heap/peak/RSS/footprint.
python3 Benchmarks/NonDecodeFourthPass/build.py \
  --output /tmp/illiquid-v4-meter-build --variants v3,v4 --allocations
python3 Benchmarks/NonDecodeFourthPass/run.py \
  --build-root /tmp/illiquid-v4-meter-build --skip-build \
  --output /tmp/illiquid-v4-meter --variants v3,v4 --repeats 3 \
  --cases 'first-fg:8190:1,miss:0:1'

# Debug candidate correctness; no debug performance comparisons.
python3 Benchmarks/NonDecodeFourthPass/build.py \
  --output /tmp/illiquid-v4-debug --variants v4 --debug
python3 Benchmarks/NonDecodeFourthPass/run.py \
  --build-root /tmp/illiquid-v4-debug --skip-build --variants v4 \
  --output /tmp/illiquid-v4-debug-tests --tests-only
```

The v3 "tests" invocation includes a known-bad duplicate diagnostic: it accounts for only one copy and leaves a file while reporting clear success. Its zero-assertion final row is **not** a passing correctness claim. Candidate runs assert the corrected behavior. The 600-operation mixed sequence compares physical regular-file lengths and counts against the index after every operation. No p95/p99 claim is made from these process cohorts.

## Existing regression runners

```sh
python3 Benchmarks/NonDecodeFollowup/run-preview.py --output /tmp/illiquid-preview-tests --tests-only
python3 Benchmarks/NonDecodeThirdPass/run-inventory.py --output /tmp/illiquid-inventory-tests --tests-only
python3 Benchmarks/NonDecodeFollowup/test-mailbox.py --output /tmp/illiquid-mailbox-tests.txt
python3 Benchmarks/NonDecodeThirdPass/test-core.py --configuration release --output /tmp/illiquid-core-tests.txt
```

The two older adapter runners now detect the extracted image-codec helper, leaving the candidate's actual `image(for:)` control flow intact. Their historical variant directory names remain unchanged; source hashes, not the old `v3` label in the inventory runner, identify the current candidate. Older numerical receipts are immutable historical data, not reruns of v4.

## Native and CI qualification

The `component-regressions` job in `.github/workflows/non-decoding-performance.yml` runs the documented correctness runners on macOS. The native lifecycle job in `.github/workflows/restoration-regressions.yml` executes the new XCTest and Swift Testing suites with the actual SDK and ImageIO. The source receipt includes `Benchmarks/` so those runners are archived alongside their production inputs. Historical timing/allocation receipts remain unchanged and describe their recorded source hashes, not subsequent review fixes.

```sh
swift test -c release --filter ThumbnailPhysicalEntryTests
swift test -c release --filter 'NativeThumbnailCacheTests|ThumbnailInventoryRegressionTests|ThumbnailPromotionMailboxTests'
# Then build the full app and run the repository's broader app/native/core tests.
```

Use a separate benchmark bundle and production-equivalent decoder/presentation policy for app traces. Existing signposts include `ThumbnailDiskRead` and `ThumbnailDiskInventory`; the new `ThumbnailExactDiskProbe` interval excludes image decode and records no media paths. Both existing explicit benchmark opt-ins and the isolated bundle identity remain required. UI presentation, filesystem fault behavior, CPU/energy/physical footprint and cold-OS-cache performance remain separate qualification gates.
