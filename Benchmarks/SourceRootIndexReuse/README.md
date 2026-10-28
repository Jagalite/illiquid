# Reusing source-root indexes for visibility edits

## Current validation

The [portable correctness run](https://github.com/Jagalite/illiquid/actions/runs/40639822935)
passed at source revision `059a0e9c34f9704470bd57ca368c9e7f124df034`.
The baseline and candidate passed 15 observer/store scenarios in debug and
release, with identical complete snapshot receipts. All eight candidate unit
tests passed in both configurations. The deliberately negative baseline reached
and failed the intended ready-index assertion.

The compact result is retained in [evidence/portable-result.json](evidence/portable-result.json).
The run artifact contains the full source/adaptation manifests, receipts, and
command logs. This check performed no performance or memory measurements.

[Native qualification and measurements](https://github.com/Jagalite/illiquid/actions/runs/40639822852)
are queued. No native speed or memory reduction is claimed until those jobs
execute successfully.


## Problem and change

At the pinned baseline, every mutation of AppModel.sourceTabs calls
SourceRootIndexStore.replace(tabs:). That includes toggling hidden items, changing
view mode, editing visibility rules, and resetting visibility. The index builder
only reads each tab's ID and items: it rebuilds file lookup dictionaries, folder
roots, and filesystem watch roots, then publishes a new snapshot asynchronously.
Replacing the index marks it unready while the work runs.

The candidate guards this one derived-index invalidation. A conservative check
requires the same tab count/order, byte-identical IDs, and equal-count item arrays
whose storage is shared while both read-only borrows are alive. Empty item arrays
are reusable regardless of capacity. Different item storage rebuilds, even when
its values compare equal. This avoids an extra file/path scan on MainActor.

The explicit initial index build, actual item-change rebuilds, revision fencing,
and sourceTabs observation remain in their existing paths. The check stores no
pointers or extra snapshots. If the builder later reads another field, the reuse
condition must be updated with it.

## Qualification design

The baseline is ea2ff568237e2667f7b1aeee67b11a44ebe95b72. The native harness stages:

- The complete production SourceRootIndex.swift, including the real async store.
- Complete NormalizedFileURL.swift and LifecyclePerformance.swift.
- Exact model declarations from AppModel.swift.
- The verbatim observed sourceTabs property and index-store declaration inside
  a small @Observable, @MainActor host.

Both variants use the same driver. The only production differences are the
observed property and SourceRootIndex's new reuse predicate. Source, extraction,
harness, binary, and log hashes are retained. Builds sharing a package are serial.

The host measures nested mutation, the actual property observer, invalidation,
detached indexing when needed, and waiting for publication. Fixture creation and
the initial index build finish before timing. Visibility normalization,
preference persistence, user-activity handling, UI rendering, and media playback
are outside this component experiment.

Every process checks its complete published snapshot against a fresh production
index, using length-prefixed, byte-exact representations. URL and item order,
dictionary key bytes, selected duplicate values, and raw item paths participate.
FNV-1a appears only as a compact receipt; the actual equality assertion compares
the complete byte sequences.

Both baseline and candidate execute 15 observer/store cases in debug and release.
The candidate also executes eight new regression tests in both configurations.
A deliberately negative baseline run must reach and fail the assertion that a
visibility edit keeps a ready index ready; a compilation error is not accepted
as the negative control.

## Timing and memory methodology

Timing uses fresh processes and six balanced AB/BA pairs. Each pair does equal
work. A one-edit calibration chooses an iteration count from the slower variant,
capped at eight. Large cases can therefore contain one edit per sample; the
candidate microsecond figures are not a long-duration throughput estimate.

Workloads include 1,000, 10,000, and 100,000 explicit files; a 100,000-file library
split across 16 tabs; and genuine removal, final-item replacement, and
independently copied equal-item controls. The removal expression is the actual
nested removeAll used by AppModel. It exposes the potential additional
copy-on-write cost of the observer's transient oldValue.

Memory uses a separate four-pair cohort, never the timing samples. A C thread
samples malloc_zone_statistics(NULL).size_in_use every 0.5 ms while the edit
runs. Peak growth is the sampled maximum minus the pre-edit live allocation
count. It is an approximate high-water measurement of live malloc bytes and
includes instrumentation overhead; shorter peaks can be missed. It is neither
total allocated volume nor a measurement of the whole player's VM/GPU memory.
ru_maxrss is also retained as a diagnostic, but includes process setup and is
not used as an update-specific savings claim.

## Reproduce

On a macOS 26 host with the repository's Swift toolchain:

    python3 Benchmarks/SourceRootIndexReuse/run.py --output /tmp/root-index-reuse --pairs 6

Use a new output directory. If Kyoto is available, submit the entire command
through the shared queue, as required by AGENTS.md. The GitHub workflow checks
that Kyoto is absent on its ephemeral host, announces the limitation, and builds
serially in isolated packages.

The native workflow also compiles the full app/test graph with the pinned native
SDK and runs the root-index, source membership, merge, and pruning regression
suites. PR runs repeat correctness qualification with --tests-only.

A separate Linux check exists to surface compile/correctness failures while
macOS runners are queued. It uses the same production models, observer, and
index/store, with explicitly recorded staged substitutions for disabled Apple
signposts, the platform import, and unavailable allocation probes. It never runs
a performance measurement and does not substitute for native qualification.

## Reference semantics

Swift arrays are value types with copy-on-write storage. The helper uses nested
withUnsafeBufferPointer calls only as a sufficient shared-storage proof; both
borrows are live simultaneously and neither pointer escapes. It intentionally
does not perform a deep item comparison on MainActor.

Swift String equality is canonically equivalent. Tab IDs are compared by UTF-8
bytes so a representation change still reaches the existing builder. Different
item buffers always rebuild, preserving the builder's handling of raw restored
paths and first-occurrence selection.

- [Array documentation](https://developer.apple.com/documentation/swift/array)
- [withUnsafeBufferPointer](https://developer.apple.com/documentation/swift/array/withunsafebufferpointer(_:))
- [String documentation](https://developer.apple.com/documentation/swift/string)
- [Apple malloc statistics declarations](https://github.com/apple-oss-distributions/libmalloc/blob/main/include/malloc/malloc.h)
