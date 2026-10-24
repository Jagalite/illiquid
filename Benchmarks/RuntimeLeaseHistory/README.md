# Runtime lease history experiment

This component experiment exercises the production runtime metadata directory and
lease ledger during session replacement. It compares main commit
`68274d1b09dcc866296321a5a8858efc297c4f19` with the current working-tree source.

```sh
python3 Benchmarks/RuntimeLeaseHistory/run.py all --output /tmp/runtime-lease-history
```

Use Swift 6.1 or later; the research run pins Swift 6.3.2. `--swift /path/to/swift`
selects a toolchain. The runner supports `build`, `test`, `measure`, and `all`.
Each new experiment requires an empty output directory; `test` or `measure` can
resume a prepared `build` directory if the source and harness hashes still match.
`--pairs 6 --histories 0,32,128,1024,8192 --cycles 128 --snapshot-calls 16` are the
defaults. Add `32768` to `--histories` for a larger optional history. An additional
8,192-history / 256-unresolved-worker control always runs.

## Exact source and behavior checks

The isolated dependency-free SwiftPM packages compile the entire production
`PlaybackRuntimeMetadata.swift`, `IdentityAndTime.swift`, and `MediaTrack.swift`.
The `ExecutorKind` enum is the exact prefix of production `EventsAndEffects.swift`.
No ledger, identity type, native API, or executor stand-in is substituted. Original
source bytes, SHA-256 hashes, compiler identity, flags, generated packages, binary
hashes, and every subprocess command/stdout/stderr are retained in the output.
Baseline/candidate dependency equality is required for the complete identity and
track files and for the exact compiled `ExecutorKind` prefix. Changes elsewhere
in `EventsAndEffects.swift` do not enter this package and may differ between
variants. Its full source bytes and hashes are still retained, and resume checks
still reject any candidate source change after preparation, including that
uncompiled remainder. Missing or ambiguous prefix boundaries remain errors.
The focused package does not replace the application's normal native build.
Test builds use a separate scratch directory from measured executables. Linux
uses SwiftPM's integrated driver to avoid a standalone-driver process-statistics
failure in restricted PID namespaces; macOS uses its ordinary driver.

The source-boundary qualification exercises preparation and resume receipts with
controlled source changes, including rejection of changed compiled dependencies.
It requires only Python and does not invoke Swift or build the packages:

```sh
python3 Benchmarks/RuntimeLeaseHistory/test_source_boundaries.py
```

The candidate runs all seven `RuntimeLeaseHistoryTests` in debug and release.
The baseline runs the two unchanged-contract tests in each configuration, then a
separate history-bound negative control. The runner requires that single test to
fail at exactly its count and ID-history assertions; compiler failures or other
failed tests do not count as successful negative controls.

Canonical comparison processes retain full, sorted JSON snapshots of **all
unresolved leases plus the last 128 confirmed releases**, both immediately after
seeding and after the replacement cohort. They compare every provenance field,
authority, effect context, disposition, and sorted borrow ID. This explicit
projection defines the new diagnostic contract; it does not claim equality with
the baseline's complete lifetime history. The independent regression tests cover
out-of-order completions and a seeded reference custody model.
Each canonical receipt also records actual retained counts before projection,
including the baseline's full retained history.

## Workload and timing

Each observation starts a fresh optimized process and warms a separate fixture.
The measured fixture holds three application graph leases, two graph borrows,
and one active session worker. The delayed-teardown control also holds 256
release-requested workers with one borrow each. Untimed seeding performs real
acquire/request-release/physical-completion operations; it skips only supersede
to avoid quadratic baseline setup while leaving the same final state.

The replacement interval performs 128 complete cycles: begin a replacement
session, supersede the prior authority, request its release, and observe physical
completion. History therefore grows from the named starting size to that size
plus 128. Snapshot inspection is timed separately for 16 calls after the cohort.
The snapshot checksum consumes the returned count and endpoint IDs; inspection
intentionally returns fewer historical rows under the new diagnostic contract.
Replacement return values and deterministic checksums must match exactly.

Pairs alternate baseline/candidate and candidate/baseline order, with sequential
fresh processes for every case. Results include wall and process CPU time,
medians, ranges, and the ratio of variant medians. Small-history cases reveal
setup and bounded-history bookkeeping costs. There is no timing threshold in CI.

## Allocator scope

The harness samples the process allocator before fixture creation, after seeding,
and after the replacement cohort, before any diagnostic snapshot allocations for
the measured fixture. Retained snapshot counts before/after come from the separate
canonical processes; the timed process also checks final custody/history counts.
On macOS the metric is `malloc_zone_statistics(NULL).size_in_use`; glibc 2.33+
uses `mallinfo2.uordblks + mallinfo2.hblkhd`. The difference from the pre-fixture
sample estimates the metadata fixture's incremental retained allocation, including
allocator/runtime effects. It is not RSS, an exact object-size sum, or whole-player
memory. Dictionary capacity can retain a prior peak in concurrent unresolved
leases, so the change does not establish a strict live-plus-128 byte bound.

This experiment measures metadata bookkeeping and diagnostics. It does not open
media or measure decoding, window composition, whole-player CPU, energy, or
input-to-screen latency. Native macOS application validation remains a separate
gate.
