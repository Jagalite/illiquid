# Startup source snapshot lifetime

This component experiment measures the extra owner retained by
`AppModel.historyStartup` after the shared model has been published. The baseline
is `6f70cd2446fc6ef38d4e5a0fbf96f91b2234e635`; the candidate is the working tree.

The runner extracts the **unchanged static startup block** from each version of
`AppModel.swift`, from `sharedInstance` through `shutdownShared`. It compiles that
block with the actual `ReadOnlyStartupLoader`, `SourceTab`, `SourceTabItem`,
source-visibility value types, and `NormalizedFileURL`. It verifies that the
loader, value types and URL normalization are identical between the two variants.
The complete input files, extracted sources and source/binary hashes are recorded
for independent checking.

## Explicit substitutions and measurement scope

The rest of `AppModel` is a small stand-in that owns its live source array and
playback-persistence reference. Playback, windowing, observation, source-root
index updates, timing diagnostics and shutdown side effects are omitted.
`SourceStartupSnapshot.load` creates deterministic in-memory source paths instead
of decoding preferences. There is one source tab with 1,000 or 100,000 explicit
file entries and approximately 100 UTF-8 bytes per path. The large case is a
stress workload, not an estimate of a typical library.

The actual `loadShared` implementation must read and initialize the model once,
drain queued startup opens once, and return that same model to a later caller.
A call after shutdown must return nil. The driver retains no startup snapshot or
Task result; the separate startup-loader regression suite covers concurrent
waiters and shutdown races.

The harness records allocator live bytes before loading, after publication,
after replacing one item, after removing all live sources, and after shutdown.
It reuses the existing `RuntimeLeaseHistory/CLeaseHeap` probe:

- macOS: `malloc_zone_statistics(NULL).size_in_use`.
- glibc: `mallinfo2().uordblks + mallinfo2().hblkhd`.

These are **aggregate component-process allocator bytes**, including runtime
allocations. They are not exact object sizes, process RSS, physical memory,
decoder memory, or a measurement of the complete player.

Buffer-address comparisons indicate whether the first edit reused the outer and
nested array storage in this isolated ownership fixture. The actual app has
observation and source-root indexing hooks; this experiment does not establish
full-app copy-on-write frequency or editing latency. No timing claim is made.

All paths are checked against their exact expected strings before and after the
edit. Full-path byte digests and semantic receipts must match for every pair.
Output encoding follows all heap measurements.

## Reproduce

Requires Swift 6.1 or newer and a C compiler, on macOS or glibc 2.33+ Linux. It
does not resolve the native application SDK.

```sh
python3 Benchmarks/StartupSnapshotLifetime/run.py \
  --output /tmp/illiquid-startup-lifetime --pairs 4 --counts 1000 100000
```

The default optimized build uses Swift 6 mode, `-O`, whole-module optimization
and warnings as errors. Use `--configuration debug` for a debug component run,
or `--validate-inputs` to check and preserve extraction without compiling.

Pairs run in separate fresh processes, sequentially, alternating baseline then
candidate and candidate then baseline. Four pairs give balanced ordering.
`manifest.json`, `commands.jsonl`, `measurements.jsonl`, `summary.json` and
`completion.json` retain the source identity, all observations, and parity gates.
No noisy timing or allocator percentage threshold is used as a correctness test.

## Recorded Linux cohort

The four-pair optimized Linux cohort is preserved under [evidence/linux](evidence/linux).
All 16 fresh-process observations passed their within-process checks and all
eight baseline/candidate semantic receipts matched. The committed files contain
the manifest, raw observations, summary and completion receipt; generated sources
and executables are reproducible and are not committed.

An initial sandboxed attempt crashed during Swift runtime process inspection
with `/proc/83/stat` in the crash trace, before its first observation. The
successful cohort ran with approved execution outside that filesystem sandbox.
The final runner and harness hashes match the recorded manifest. These Linux
component results do not qualify the native macOS application graph.
