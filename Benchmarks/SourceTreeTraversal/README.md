# Source-tree traversal scratch storage

This experiment targets cycle-detection storage in
`SourceTreeProjectionInput.rows()`. The original recursive folder traversal
creates a new ancestor `Set<String>` for every folder with
`visitedFolderIDs.union([folderID])`. Those sets remain alive along the active
recursion path. A flattened root also constructs a one-element seed set for
each child.

The candidate allocates one traversal-local set, passes it by `inout`, inserts
the current folder on entry, and removes it with `defer` on every exit. The set
contains only the current path. Shared subtrees and repeated roots must still
produce their original occurrences; this is not a globally visited set.

The expected benefit is less allocation and reference-counting work when
building folder rows. Cycle-detection scratch storage scales with maximum
depth instead of the sum of active path lengths. The row output still owns its
existing ancestor arrays; this change does not reduce that output's size or
promise a different total-memory complexity.

## Scope and status

The comparison baseline is commit
[ea2ff568237e2667f7b1aeee67b11a44ebe95b72](https://github.com/Jagalite/illiquid/commit/ea2ff568237e2667f7b1aeee67b11a44ebe95b72).
Native macOS component qualification is pending. No performance result is
claimed until the measurements and behavior checks complete.

The change is confined to tree-row construction. Sorting, row identity, stored
expansion preferences, filesystem access, visibility rules, playback, and media
decoding are outside the implementation change. No additional production cache
or long-lived index is introduced.

## Reproduce

From a checkout containing the baseline commit:

```sh
git fetch --no-tags --depth=1 origin ea2ff568237e2667f7b1aeee67b11a44ebe95b72
python3 Benchmarks/SourceTreeTraversal/run.py \
  --output /tmp/illiquid-source-tree-traversal \
  --pairs 6 --target-ms 25
```

The runner uses the repository's shared Kyoto queue when available. Otherwise
it reports the limitation before building serially in isolated Swift package
directories. It needs macOS, Swift, Python, and Git, with no FFmpeg dependency or
network access for Swift packages.

## Method

The runner reuses `Benchmarks/SourceTreeVisibility/run.py`'s guarded source
snapshotting. `SourceTreeProjectionInput.swift` is copied unchanged from the
pinned baseline and the candidate checkout. All support sources are identical
between variants. Source hashes, staging receipts, compiler information, commands,
test logs, raw measurements, complete verification output, and summaries are
retained in the output directory.

Both variants run the existing source-browser and tree-cache regressions and
the new traversal regressions in debug and release. The new checks exercise
cycles, repeated roots, shared descendants, early returns, and cancellation.

The release benchmark compiles production code into a separate Swift module
from its driver. It compares complete ordered row receipts before timing,
including IDs, URLs, names, depth, ancestor lists, row kinds, and presence
metadata. The fixtures have no recognized-media or visibility annotations;
the driver checks that condition.

Six fresh-process pairs alternate baseline/candidate and candidate/baseline
order. Each timing process performs one untimed projection and full output
fingerprint, then measures repeated row construction. Input creation, output
fingerprinting, and output destruction are outside each timed interval. The
driver checks output count after every call. CPU time comes from `clock()`;
wall time comes from `DispatchTime`. Timing results describe this component,
not user-visible sidebar latency or end-to-end playback performance.

| Case | Shape | Purpose |
| --- | --- | --- |
| `wide_collapsed_10000` | One root, 10,000 collapsed child folders | Repeated shallow scratch allocation |
| `library_9600` | 40 categories × 10 shows × 4 seasons × 6 media files | Library-shaped workload, 11,640 output rows |
| `balanced_tree` | Four child folders for five levels, two files per leaf | Expanded branching traversal, 3,412 rows |
| `deep_chain_128` | 128 nested folders, one media file at every level | Depth stress |
| `deep_chain_512` | 512 nested folders, one media file at every level | Extreme synthetic depth stress |
| `flat_files_10000` | 10,000 explicit media files | Control without recursive folder traversal |

Sort criteria are disabled in these fixtures so both variants retain input
order and the measurements focus on row construction. Existing regression
tests cover sorting and cached projection behavior separately.

## Memory interpretation

Each memory observation runs in a fresh process without a projection warmup.
It records Darwin's process peak resident memory before and after one
projection, plus allocator-accounted live heap bytes while the output remains
alive. Complete output fingerprinting occurs after those memory readings.

Peak-RSS growth is a process high-water measurement. It can underreport
transient work if fixture construction already established a higher peak, and
is affected by allocator reuse and page granularity. It is not an allocation
count or an exact measurement of the ancestor sets. Live-heap growth mainly
measures retained output and should remain similar because the output format
is unchanged. The API definitions are in Apple's [malloc header](https://github.com/apple-oss-distributions/libmalloc/blob/main/include/malloc/malloc.h)
and [Darwin getrusage manual](https://github.com/apple/darwin-xnu/blob/main/bsd/man/man2/getrusage.2). Depth-stress results must not be generalized to typical media
libraries.

The compiler and standard-library rules motivating the experiment are described
in [Swift's optimization guidance](https://github.com/swiftlang/swift/blob/main/docs/OptimizationTips.rst)
and [Apple's collection value-semantics documentation](https://developer.apple.com/documentation/swift/array).
The measured result, rather than the source-level allocation model, determines
whether this candidate is retained.
