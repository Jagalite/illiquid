# Startup snapshot lifetime

This experiment measures obsolete saved-source state retained by the startup
loader after `AppModel` adopts it. The production fix finishes that loader
immediately after publishing the shared model. Already-admitted startup callers
can still return; shutdown still rejects late results.

The baseline is `6f70cd2446fc6ef38d4e5a0fbf96f91b2234e635`. Its original
`ReadOnlyStartupLoader.swift` and two existing tests are frozen under `baseline/`
with source hashes. Both variants use the same unchanged, exact production
source models extracted from `AppModel.swift`, `SourceStartupSnapshot.swift`,
and `NormalizedFileURL.swift`. The candidate uses the current production loader
and tests. The runner also verifies that the real app calls `finish()` after
publishing the shared instance, with no intervening suspension.

## Reproduce

Requires Swift 6.1 or newer and Python 3.10 or newer. The recorded local cohort
uses Swift 6.3.2. No Swift package download or native codec SDK is needed for
this component experiment.

```sh
python3 Benchmarks/StartupSnapshotLifetime/run.py \
  --output /tmp/startup-snapshot-results \
  --pairs 6 --sizes 1,32,1000,10000,100000
```

Use a new or empty output directory. For current correctness tests without
repeating the historical experiment:

```sh
python3 Benchmarks/StartupSnapshotLifetime/run.py \
  --output /tmp/startup-snapshot-tests --tests-only
```

The macOS workflow runs component measurements on the dedicated research branch
or by manual dispatch. PR runs execute the current debug/release correctness
tests instead of repeating the historical baseline benchmark. A separate native
job builds the real app graph and runs startup, pending-open, and source-tab
integration suites with the repository's pinned SDK.

## What is measured

`count` means **saved explicit source file items**, distributed across up to four
tabs. It does not count every video discovered recursively inside a source
folder. A folder containing 100,000 videos can occupy one saved source item. The
10,000/100,000-item fixtures are stress workloads, not a typical library claim.

The read closure constructs and restores real `SourceTab` values through
`SourceTabStore`. It captures only a scalar count. Construction arrays, encoded
JSON, and the local startup result leave scope before the samples. The fixture
model adopts the same source values as `AppModel`, without constructing the
native player, UI, `SourceRootIndexStore`, or a real preferences domain.

| Scenario | Operation after adoption |
| --- | --- |
| `unchanged` | Keep all restored tabs and their shared storage alive. |
| `append-item` | Append one file to the first tab; probe its first nested array mutation. |
| `remove-half` | Close the trailing half of tabs, rounding up. |
| `remove-all` | Close every restored tab. |
| `replace-visibility` | Clear all restored custom visibility configurations. |

The initial model and startup snapshot share copy-on-write array storage. No
large immediate startup reduction is expected in `unchanged`. The baseline
holds the *original* restored snapshot after changes; it does not accumulate
every subsequent version.

The primary metric is post-mutation live allocator bytes minus the warmed
pre-load value:

- macOS: `malloc_zone_statistics(NULL).size_in_use`.
- Linux/glibc: `mallinfo2().uordblks + mallinfo2().hblkhd`.

These are process-wide allocator counters inside a small component probe, not
whole-player resident/physical memory, peak memory, or GPU memory. Tiny cases
can be dominated by runtime/allocator noise. No memory-pressure purge or forced
allocator trim is used.

Each baseline/candidate observation runs in a fresh process. Every workload
uses balanced AB/BA pairs; workload order rotates between pairs. Tests and probes
use separate build directories. Sources and measured binaries are hashed before
and after the experiment. All raw observations and command receipts are kept.

The actual measured model is serialized only after the primary memory/timing
samples. Set contents are sorted for deterministic JSON. Each pair compares the
complete output bytes, records its SHA-256 and length, and deletes the temporary
state payloads after equality succeeds. The later model-release/cleanup samples
are diagnostic: serialization can populate additional runtime caches.

Mutation wall/process CPU times include any object destruction moved into the
mutation. They are single-operation descriptive observations, not a calibrated
speed benchmark or a performance acceptance gate. Releasing obsolete data can
make closing a tab take longer than merely retaining its contents until quit.

## Evidence and interpretation

See [the research report](../../Documentation/STARTUP_SNAPSHOT_MEMORY.md) for
measured results, validation, and limitations. The workflow preserves JSON,
JSONL, compiler/test logs, source/binary receipts, and a checksummed compressed
copy in its job log so the experiment can be audited independently.

The fix changes resource ownership only. It does not change source selection,
source persistence format, startup read coalescing, or playback buffering.
