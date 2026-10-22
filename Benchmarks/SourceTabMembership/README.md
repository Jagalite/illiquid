# Source-tab membership qualification

This harness measures one `SourceTabs.contains(candidate, in: tab)` call. The
candidate reuses the query's normalized identity within a membership check. The
frozen baseline is commit `7f9ba073394b77a908e0589447c6edc8d10b832c`.

```sh
python3 Benchmarks/SourceTabMembership/run.py \
  --output /tmp/illiquid-membership-results --pairs 8 --target-ms 60
```

`--output` must be new or empty. `--tests-only` runs both implementations in
debug and release and verifies the exact benchmark input/output receipts without
collecting timings. Set `SWIFT` or add the desired toolchain to `PATH` when needed.
The package needs only the toolchain's Foundation and bundled Swift Testing; it
does not resolve the app's external dependencies.

## Source integrity and correctness

The harness extracts the complete production region beginning with
`struct SourceTabItem:` and ending immediately before
`private struct PlaybackLifecycleObservation:` in `AppModel.swift`. The region
contains the actual source-tab types and predicates, with only `Foundation` and
`IlliquidCore` import statements prepended. It compiles the actual
`NormalizedFileURL.swift` as a separate `IlliquidCore` module. The frozen files,
extraction boundaries, original full-file hash, and excerpt hashes are recorded
in `baseline/manifest.json` and checked before execution.

Both variants compile into independent minimal SwiftPM packages with the same
regression tests and driver. `IlliquidApp` enables testing so the driver can
import its internal declarations across a real module boundary. No production
predicate is rewritten or inlined into the driver, and cross-module optimization
is not enabled.

The runner executes `SourceTabMembershipTests.swift` in debug and release for
both implementations. In addition, the driver checks every benchmark query
against an untimed copy of the original predicate. Baseline and candidate must
produce identical receipts containing all stored item paths, all absolute and
relative query URLs, base URLs, and exact membership booleans. Every timed
invocation retains a boolean result and contributes to a checked weighted
checksum.

## Workloads and measurements

The 22 workloads cover empty tabs; single file/folder hits and misses; 64/1,000
item last hits and misses; 1,000-item first hits; a mixed 128-item tab; Unicode and
relative queries; decoded noncanonical item paths; and nonfile or unsupported
file-authority inputs. Folder fallback for unsupported file identities is
deliberately preserved and exercised separately from file-item rejection.

Fixtures use a runtime seed and are constructed before measurement. Each batch
performs 16 lookups. Both variants independently calibrate to approximately the
requested duration, with at least one batch, and all results are normalized per
lookup. Measurements use fresh processes in balanced AB/BA pairs, with workload
order rotated between pairs. An even pair count is required.

Monotonic wall time and process CPU time cover only repeated lookup batches.
Construction, decoding, oracle calculation, warmup, final validation, and JSON
encoding are outside the timed interval. Measurements include the query loop,
boolean stores, checksum accumulation, and timer overhead; no empty-loop cost is
subtracted. Empty-tab timings primarily describe this overhead. Process CPU time
includes all process threads and remains sensitive to CPU frequency and cache
state.

`manifest.json`, staged source packages, source/build hashes, test logs, exact
verification receipts, calibration records, raw `measurements.jsonl`, and
`summary.json` form the evidence. Summaries retain every paired sample and report
medians and the number of pairs where the candidate was faster; they impose no
noisy timing threshold on correctness tests.

These are in-memory component measurements. They do not measure source-folder
scans, UI latency, decoding, playback CPU, memory usage, battery life, or energy.
Linux results are preliminary; the macOS workflow measures native Foundation
with the same source and harness.

## Fixed-count short-path diagnostic

The native workflow also runs this bounded check using the release binaries
already produced above:

```sh
python3 -B Benchmarks/SourceTabMembership/controls.py \
  --evidence /tmp/illiquid-membership-results --pairs 8 --iterations 2048
```

Six singleton/first-hit workloads each receive eight fresh-process paired
comparisons of baseline against candidate and eight independent comparisons of
the baseline binary against itself. All labels perform exactly 2,048 batches
(32,768 lookups) per sample, without calibration. The default eight pairs balance
label order and comparison position; workload order rotates. All 192 samples
are retained under `control-check/`.

The script verifies staged-source and executable hashes, passing parent test
receipts, and fresh exact fixture/output receipts before timing. It does not
rebuild or substitute the production code. The same-binary comparison diagnoses
runner variability; its percentages are not subtracted from the candidate
results or treated as proof of common-path neutrality. Smaller local runs are
execution checks, not native timing evidence.

## Recorded research

See the [research report](../../Documentation/SOURCE_TAB_MEMBERSHIP_PERFORMANCE.md)
for native results, the first-item refinement, and limits on interpretation.
[Retained evidence](evidence/README.md) includes favorable and unfavorable
observations from both native candidates. Generated build directories are not
checked in; immutable commits, extraction boundaries, and source/build hashes
identify the measured inputs.
