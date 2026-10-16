# Third non-decoding performance pass

This directory contains the **v2-versus-v3** comparison, regression evidence,
and a separate **progress-only SQLite feasibility experiment**. It is not a
complete application checkout or a replacement persistence provider.

Read `Documentation/NONDECODING_PERFORMANCE_THIRD_PASS.md` for the decisions,
negative controls, known remaining duplicate-cache issue, and native release gates.
Existing v1/v2 work and receipts remain in their original benchmark directories.

## Executed scope and environment

The submitted run used Linux x86-64, Swift 6.2.1, and a shared host reporting
Intel Xeon Platinum 8573C. Sources compile with `-O -swift-version 6
-warnings-as-errors`. The actual history store, writer, Foundation JSON,
UserDefaults, and supporting production value types execute in the store tests.
The supporting enum fixture contains extracted production declarations.

Inventory tests execute the real Foundation directory/stat/unlink paths and
cache bookkeeping, with explicit image adapters solely to compile the selected
native module. **No image codec executes in the inventory measurement.**
The existing preview integration tests do use synthetic, non-JPEG adapters.
These are not macOS ImageIO/CoreGraphics or complete hover-latency tests.

**Storage warning:** this run's filesystem reports `fsync=volatile`. SQLite
`PRAGMA synchronous=FULL` was set and checked, but the observed commit times
cannot be called physical SSD/durable-commit latency. Process-kill recovery is
not host-crash or power-loss recovery. `evidence/environment-v3.json` records
the mount evidence. Inspect the filesystem and durability boundary on every host.

## Run selected-source regressions

Requirements: Python 3.10+, a Swift 6 toolchain, and the surrounding cumulative
candidate files. The Linux image adapter needs OpenSSL/libcrypto for linking;
allocation measurements additionally need clang and glibc. Full macOS tests need
the repository's native SDK/dependency setup and supported macOS/Xcode versions.

```sh
python3 Benchmarks/NonDecodeThirdPass/test-core.py \
  --output /tmp/illiquid-v3-core-release.txt
python3 Benchmarks/NonDecodeThirdPass/test-core.py --configuration debug \
  --output /tmp/illiquid-v3-core-debug.txt
python3 Benchmarks/NonDecodeThirdPass/run-inventory.py --tests-only \
  --output /tmp/illiquid-v3-inventory-tests
python3 Benchmarks/NonDecodeThirdPass/run-edge-cases.py \
  --inventory-build /tmp/illiquid-v3-inventory-tests \
  --output /tmp/illiquid-v3-inventory-edges
```

Every output path must be new/empty. The edge diagnostic is deliberately not an
all-green clearance: it **records an existing duplicate-digest defect** in both
variants, while asserting the unchanged over-capacity and foreground-tier cases.
A zero exit status means the diagnostic completed, not that its duplicate case
was fixed. The synthetic cache files are not user images or valid JPEG fixtures.

To reproduce the v2 preference defect, this command is **expected to fail**:

```sh
python3 Benchmarks/NonDecodeThirdPass/test-core.py --v2 \
  --filter IdempotentPersistenceTests.testVolumeAndSpeedPreserveHistoryOptOutAndRestorePreference \
  --output /tmp/illiquid-v2-expected-preference-failure.txt
```

On the supported Mac checkout, run the real application graph and existing
regressions, including the new test classes; the portable runs do not replace it:

```sh
swift test -c release --filter 'IdempotentPersistenceTests|DeferredPersistence'
swift test -c release --filter 'ThumbnailInventoryRegressionTests|NativeThumbnailCacheTests|ThumbnailPromotionMailboxTests'
```

The five new native inventory tests were syntax-parsed, not SDK-typechecked or
executed in this environment. No complete SwiftPM app build was performed here.

## Timing and separate allocation measurements

Run only one experiment at a time. Outputs include each raw process result,
commands, source/binary hashes, and medians with min/max. No compiled binaries
are included in the delivered evidence; drivers rebuild them.

```sh
python3 Benchmarks/NonDecodeThirdPass/run-history.py \
  --counts 1000,10000 --repeats 5 --output /tmp/illiquid-v3-history-small
python3 Benchmarks/NonDecodeThirdPass/run-history.py \
  --counts 100000 --repeats 3 --output /tmp/illiquid-v3-history-large
python3 Benchmarks/NonDecodeThirdPass/run-inventory.py \
  --repeats 5 --output /tmp/illiquid-v3-inventory

# Linux/glibc only. Requested bytes are NOT live heap or footprint.
python3 Benchmarks/NonDecodeThirdPass/run-history.py --allocations \
  --counts 10000,100000 --modes repeat-blocked,changed-blocked --repeats 3 \
  --output /tmp/illiquid-v3-history-allocations
python3 Benchmarks/NonDecodeThirdPass/run-inventory.py --allocations \
  --cases valid:8191,malformed:8191 --repeats 3 \
  --output /tmp/illiquid-v3-inventory-allocations
```

For a bounded execution window, the history driver accepts `--max-observations N`.
Resume with the same output and `--resume`; sources and binary hashes must match.
Completed observations are never overwritten. A summary describes the groups
requested by that invocation. The packaged `formal-history/all-groups-summary.json`
aggregates the whole unequal-repetition cohort (130 rows), whereas its original
`summary.json` describes the last requested 100k subset. Raw rows are authoritative.

Seven inventory cases are measured by default: empty/1k/8191 valid names, 8191
and 32768 malformed `.jpg` names, 32768 unrelated files, and a 10%-valid mixed set.
Fixtures are freshly created before timing; **OS caches are warm**, not purged.
The timed interval is inventory, not JPEG decoding, extraction, or visible UI.

## SQLite experiment, deliberately separate

```sh
python3 Benchmarks/NonDecodeThirdPass/sqlite-experiment.py \
  --repeats 3 --output /tmp/illiquid-sqlite-progress-experiment
```

Uses Python's sqlite3 binding, WAL/FULL, explicit transactions, a nominal 2 MiB
page cache, and a single progress table. It checks rollback, separate-reader
visibility, 10k deterministic updates, reopen, and ten kills of its own child
processes. It does **not** provide production version archives, migration,
settings, hydration, preference precedence, or app integration. Never point it
at installed app data. Do not compare its raw timing directly to the Swift JSON
store or call it power-loss qualification.

## Evidence map

`evidence/validation-summary.json` summarizes counts and limits. Each `formal-*`
folder retains `measurements.jsonl`, manifests, and original command receipts.
`formal-history/all-groups-summary.json` is the complete history aggregation.
`sqlite-experiment/tests.json` records logical recovery outcomes.
`inventory-edges/results.json` records the known duplicate case.

`timed-sources/NativeThumbnailDiskCache.swift` preserves the exact unmetered
inventory source. The final production file differs **only in comments** clarifying
that FileManager may perform internal metadata I/O; metered runs and final tests
used the clarified file. Hashes and a non-comment-line equality check are recorded
in `evidence/comment-clarification.json` and `evidence/source-verification.json`.
Historical commands contain original temporary paths; those are receipts, not
installation requirements. A new working directory naturally changes those paths.
