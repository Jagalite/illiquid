# Startup source snapshot lifetime

## Finding

The static `AppModel.historyStartup` loader retained its completed
`StartupResources` until application shutdown. Those resources included the
restored `SourceStartupSnapshot`. `AppModel` adopted `sources.tabs`, but nothing
retired the loader's copy when the shared model was published.

Initially this is shared copy-on-write storage, rather than two complete copies
of every item. After source tabs, explicit file lists, or visibility settings
change, the static cache continues retaining the *original* restored values.
Closing all restored tabs therefore leaves their old arrays and path strings
alive until quit. The retained state is one original snapshot, not every
intermediate edit. The persistence store is a shared class reference; this
finding does not establish a second copy of the complete playback history.

Relevant production sources:

- `Sources/IlliquidApp/App/AppModel.swift`: startup resource construction,
  shared model publication, and adoption of `sources.tabs`.
- `Sources/IlliquidApp/App/ReadOnlyStartupLoader.swift`: cached result ownership.
- `Sources/IlliquidApp/App/SourceStartupSnapshot.swift`: saved tabs and selection.

Swift's [Array documentation](https://developer.apple.com/documentation/swift/array)
describes the shared storage and first-mutation copy-on-write behavior behind
this distinction.

## Change and correctness

`ReadOnlyStartupLoader` now distinguishes three states:

| State | New caller | Already admitted caller completing |
| --- | --- | --- |
| Active | Start/join the read, or return the cache | Cache and return its result |
| Finished | Return `nil` | Return without repopulating the cache |
| Stopped | Return `nil` | Reject the result |

`AppModel.loadShared()` calls `finish()` immediately after assigning
`sharedInstance`. Both operations run synchronously on `MainActor`. Existing
scene/delegate callers still receive their result and use the existing
shared-instance recheck. Subsequent app callers return that shared model without
reading the finished loader. Shutdown retains its late-publication rejection.

Finishing clears the cache and stored task reference. It does not cancel a
pending caller. Normal app use finishes only after the shared read has completed.
The generic loader also permits finishing before an in-flight read resolves;
after that transition `stop()` still rejects its result but no longer holds the
task handle needed to deliver a cancellation request to that read.

The source persistence format, selection rules, pending-open request ordering,
and playback buffers are unchanged.

## Experiment

The baseline is `6f70cd2446fc6ef38d4e5a0fbf96f91b2234e635`.
[The reproducible benchmark](../Benchmarks/StartupSnapshotLifetime/README.md)
stages the exact production loader, source snapshot, path normalizer, and source
models. It uses a minimal value owner in place of the native app graph.

The cohort consists of 1, 32, 1,000, 10,000, and 100,000 saved explicit file items,
distributed across up to four source tabs, with path-based visibility settings.
Each size is measured unchanged, after appending one item, after closing half
the tabs, after closing all tabs, and after clearing visibility settings. Six
balanced AB/BA pairs per workload produce 300 fresh processes per platform.

Saved explicit items are not a recursive inventory: a folder containing
100,000 videos can occupy one source item. The two largest fixtures are stress
cases. Ordinary small-source configurations are included as controls.

The primary metric is the change in live allocator bytes from a warmed pre-load
sample to the post-mutation sample. macOS uses
`malloc_zone_statistics(NULL).size_in_use`; glibc uses
`mallinfo2().uordblks + mallinfo2().hblkhd`. Complete measured state is serialized
after primary sampling and compared byte-for-byte within every pair. Build,
source, binary, command, and full observation receipts are preserved.

## Native macOS results

Measured on macOS 26.6.2, Apple Silicon arm64, Apple Swift 6.3.3, using
[workflow run 40101057617](https://github.com/Jagalite/illiquid/actions/runs/40101057617)
at source commit `160b6f4c0ba77fbbabf2c40b08dfa02cba1bdd1d`.

The table shows live allocator deltas relative to the warmed pre-load sample
**after closing all restored source tabs**. These are component allocations,
not total player memory.

| Saved explicit items | Baseline delta (bytes) | Updated delta (bytes) | Paired median reduction |
| ---: | ---: | ---: | ---: |
| 1 | 752 | 160 | 78.7% |
| 32 | 6,496 | 160 | 97.5% |
| 1,000 | 161,856 | 2,656 | 98.4% |
| 10,000 | 1,709,312 | 160,800 | 90.6% |
| 100,000 | 15,820,080 | 211,152 | 98.7% |

At 100,000 saved items, this is **15.087 MiB → 0.201 MiB**, a saving of
**14.886 MiB**. All six pairs saved exactly 15,608,928 bytes in that workload.
Other mutations in the same stress fixture also reduce obsolete retention:

| Mutation, 100,000 saved items | Median paired bytes saved | Reduction |
| --- | ---: | ---: |
| Append one item to the first tab | 610,080 | 3.7% |
| Close the trailing half of tabs | 7,806,400 | 49.3% |
| Clear custom visibility settings | 3,584,096 | 22.7% |

The unchanged 1-item and 32-item controls are exactly neutral. At 100,000 items,
the unchanged median difference is only 3,616 bytes (0.023%), consistent with
retaining the same live source values rather than reclaiming a large duplicate
at startup. No broad launch-memory improvement is claimed.

Small outliers remain in the evidence: one 1-item close-half pair retained 4,800
more bytes, and one 32-item append pair retained 4,912 more bytes. A 10,000-item
unchanged pair was also 3,504 bytes higher. These were retained, not discarded.
The larger changed-state workloads improve in all six pairs.

### Reclamation cost

Closing tabs now destroys obsolete objects during the mutation instead of
leaving them reachable until shutdown. Median single-operation wall times:

| Operation | Baseline | Updated |
| --- | ---: | ---: |
| Close all, 32 items | 1.67 µs | 4.94 µs |
| Close all, 1,000 items | 4.04 µs | 35.23 µs |
| Close all, 10,000 items | 4.33 µs | 280.42 µs |
| Close all, 100,000 items | 5.54 µs | 3.094 ms |
| Close half, 100,000 items | 7.46 µs | 1.536 ms |
| Clear visibility, 100,000 items | 8.25 µs | 0.727 ms |

The 100,000-item append observation fell from 0.238 ms to 0.072 ms, but this is
not a calibrated timing experiment. Memory ownership and state correctness are
the acceptance criteria; the timings expose the moved destruction cost.

## Validation and evidence

- Native component job passed: five baseline tests and ten candidate tests in
  both debug and release, with warnings treated as errors. The candidate includes
  seven real-loader ownership/coalescing/shutdown tests and three production
  source-startup restoration tests.
- All 300 measurement processes succeeded, with 150 complete model-state
  byte comparisons. Every workload has three AB and three BA pairs.
- An independent Python audit reconstructed all 25 expected states, including
  path sets, selection, checksums, JSON byte lengths, and SHA-256 hashes. Every
  result matches the native probe receipts.
- The audit recomputed every summary statistic, checked all 13 source-input
  hashes and staged-source receipts, and connected every observation to its raw
  process log and executable variant.
- The CI runner rehashed measured binaries and source files after the experiment.
  Binary hash receipts are preserved; executable files themselves are not in the
  evidence bundle, so the independent audit does not rehash those binaries.
- The real app graph built successfully in release with the pinned native SDK.
  All 27 tests in six startup/source suites passed: startup loading, pending launch
  URLs, source restoration, navigation, membership, and tab merging. The
  [integration receipt](../Benchmarks/StartupSnapshotLifetime/evidence/macos-arm64/native-integration-receipt.json)
  records the exact job and raw-log hash. The build contains existing warnings in
  native Metal and unrelated tests; the changed loader/test files report none.

The complete immutable component evidence is in
[`Benchmarks/StartupSnapshotLifetime/evidence/macos-arm64`](../Benchmarks/StartupSnapshotLifetime/evidence/macos-arm64):
[summary](../Benchmarks/StartupSnapshotLifetime/evidence/macos-arm64/summary.json),
[source/environment manifest](../Benchmarks/StartupSnapshotLifetime/evidence/macos-arm64/manifest.json),
[independent audit](../Benchmarks/StartupSnapshotLifetime/evidence/macos-arm64/independent-audit.json),
and [compressed full receipt/log bundle](../Benchmarks/StartupSnapshotLifetime/evidence/macos-arm64/native-component-bundle.json.gz).
The bundle's SHA-256 is
`47d98874f0ec736883d5cb68d138a8f51104d1d8d9c19d0b4eaf2de84493eb9a`.

Earlier Linux development runs passed their ownership tests and a 300-process
comparison. Their raw cohort was lost in a workspace restart; no Linux numeric
results are used for qualification or the tables above.

## Interpretation and limits

These measurements cover source-state ownership in an isolated process. They do
not include the native playback graph, UI observations, the derived source-root
index, a real preferences domain, filesystem scans, GPU memory, or decoder
buffers. They are live allocator measurements rather than resident/physical
memory or peak-memory measurements.

The unchanged control should show no large gain because the adopted model still
needs the shared values. Small differences can be dominated by allocator and
runtime bookkeeping. Do not extrapolate a large-fixture percentage to ordinary
player memory use.

Releasing obsolete data moves destruction into the source edit/close operation.
The benchmark retains mutation wall and process CPU time to expose that tradeoff.
Those single-operation timings are descriptive; they are not calibrated
end-to-end UI latency or a playback-FPS claim. Final release/cleanup heap samples
are diagnostic because they follow JSON serialization, which can populate
runtime caches.
