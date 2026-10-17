# Source filesystem event-routing audit

Date: 2026-10-17. Baseline: `8c3cc3d4008d5d1b8d436bcf2d51d891382b6548`.

## Scope and findings

This investigation started from `main`, not another PR's implementation. Open PRs
were checked for overlap. The retained change concerns source-browser filesystem
invalidation only; it does not change playback, subtitles, filename recognition,
metadata IDs, saved history, or source selection.

Two independently reproduced routing defects could leave source listings stale:

1. Both event planning and active-source impact checks used
   `path.hasPrefix(rootPath + "/")`. With `/` as the root this becomes `//`, so
   descendant events are ignored. Conversely, a filesystem-wide rescan at `/`
   misses nested watched roots. A full-root rescan also fails to subsume existing
   descendant invalidations. `/` is already explicitly supported by
   `SourceRootPruning`; this change does not add it to anyone's sources.
2. The mount/unmount callback selected only roots equal to or inside the affected
   volume. A watched ancestor such as `/Volumes` or `/` was omitted when
   `/Volumes/Media` changed. The callback then returned before its existing
   stream restart and invalidation steps. Exact and descendant roots worked;
   sibling prefixes such as `/Volumes/Media2` must still be excluded.

Apple documents that `NSWorkspace.volumeURLUserInfoKey` carries the volume's
mount path, and that a volume can mount underneath a monitored path. These
contracts support checking ancestry in both directions, rather than requiring
the watched folder to be on the affected volume:

- [NSWorkspace volume path](https://developer.apple.com/documentation/appkit/nsworkspace/volumeurluserinfokey)
- [FSEvents mount-event semantics](https://developer.apple.com/la/documentation/coreservices/1455361-fseventstreameventflags/kfseventstreameventflagmount)

## Implementation

The existing event, plan, and planner types move unchanged in visibility to
`SourceFilesystemInvalidation.swift`, which depends only on Foundation. One
shared lexical containment helper handles `/` and preserves component boundaries.
The native callback delegates its root selection to the tested planner helper.
The remainder of the native adapter is byte-for-byte unchanged after extraction.
No additional filesystem lookup, cache, timer, observer, or persistence write is
introduced by the helper.

A dedicated runner avoids editing the shared restoration runner used by other
work. On macOS it also copies and compiles the real `SourceFilesystemMonitor`
and its real `LifecyclePerformance` dependency, without mock native APIs. The
new macOS workflow uses the same runner, Xcode path, and pinned checkout action
as the existing restoration workflow.

## Executed validation

Local environment: Linux x86_64, Swift 6.2.1. Tests use toolchain-provided Swift
Testing in an isolated package, not the app's pinned Swift 6.3.2 dependency graph.

| Experiment | Result |
| --- | --- |
| Original planner and original volume predicate, new and existing tests | 104 failed expectations; existing synchronization suite still passes |
| Candidate, debug, warnings as errors | 21 test definitions / 2 suites pass |
| Candidate, release, warnings as errors | 21 test definitions / 2 suites pass |
| Reintroduce only the broken `/` containment expression | Tests reject it: 93 failed expectations |
| Remove only the ancestor-volume matching arm | Tests reject it: 22 failed expectations |
| Native adapter syntax parsing, shell syntax, diff whitespace | Pass |

These counts are assertions about two related bugs, not counts of distinct bugs.
The 10 original synchronization test definitions are unchanged. The 11 additions
cover file/directory events, all four full-rescan flags, rescan coalescing in both
input orders, impact queries, exact/ancestor/descendant volume roots, unrelated
volumes, empty inputs, nonexistent paths, and lexical normalization. A matrix
checks 121 root/event pairs against an independent path-component ancestry oracle.

The baseline source blob was verified as
`5d72b86349b8655e7188cd4f551ffd7816637abf`; the existing test blob as
`2ca3be6d4c8d736598939f78c161a0f04f49d3c9`. Baseline testing extracted the
Foundation-only declarations verbatim from the original monitor. A thin static
wrapper made the original callback's `watchedRoots.filter` predicate callable;
the predicate itself was not rewritten. This does **not** execute NSWorkspace
or FSEvents on Linux. The candidate runner copies production sources and tests
without source rewriting.

Reproduce the candidate from the repository root:

```sh
bash Scripts/test-source-filesystem-regressions.sh --jobs 2 -Xswiftc -warnings-as-errors
bash Scripts/test-source-filesystem-regressions.sh -c release --jobs 2 -Xswiftc -warnings-as-errors
```

## Remaining qualification and tradeoffs

At PR creation, macOS compilation and test execution are pending CI. Local syntax
parsing does not type-check native APIs. Neither local tests nor the dedicated
workflow mounts a volume, starts FSEvents, or runs the full application.

Before release, exercise a real macOS mount/unmount/reconnect with both a source
inside the volume and a source containing its mount point. Verify that the
browser refreshes, a similarly named sibling volume is unaffected when watched
alone, and file create/rename/delete updates reach an explicitly selected `/`
source. Verify stream reattachment and UI behavior, not merely the pure plan.

The existing full-root rescan policy is retained. Correctly refreshing a broad
root can do more work than incorrectly ignoring the event; this is not a CPU,
latency, or energy optimization claim. Apple specifically cautions against
unbounded scans of newly mounted non-local filesystems. This patch does not
expand the set of selected roots or change scan scheduling/budgets.

Saved-history corruption, file identity after a move, and reconnect recovery of
active playback are not claimed reproduced or fixed by this pass.
