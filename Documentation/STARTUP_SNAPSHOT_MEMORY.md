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

## Qualification status

The production loader's seven ownership/coalescing/shutdown tests passed locally
in debug and release. The initial 80-process smoke comparison also passed all
baseline and candidate source-snapshot tests and all 40 full-state byte
comparisons. Full platform measurements and native app integration results are
being collected on the research branch before opening a PR.

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
