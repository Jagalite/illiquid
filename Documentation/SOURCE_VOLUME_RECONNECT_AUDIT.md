# Source volume-notification audit

Date: 2026-10-17. Baseline: `8c3cc3d4008d5d1b8d436bcf2d51d891382b6548`.

## Scope and concurrent work

This investigation started from `main`, independently of the playback pipeline.
A final direct PR check found concurrently created PR #12 covering the general
filesystem-root event-planner defect. That overlapping fix, extraction, test
runner, and workflow have been removed from this PR's final diff. PR #12 owns
that work. This patch retains only the distinct volume-notification selection
bug; it neither changes nor depends on PR #12's branch.

The only existing production code changed is the root-selection expression in
`SourceFilesystemMonitor.volumeChanged(path:)`. A small Foundation-only policy
makes that expression independently testable. The rest of the native adapter,
including its existing event planner, observer lifecycle, event flags, and
stream restart sequence, is unchanged from main.

## Confirmed defect

The original mount/unmount callback selected only watched roots equal to or
inside the changed volume. A source containing the mount point was omitted:

| Watched source | Changed volume | Original selection | Correct selection |
| --- | --- | --- | --- |
| `/Volumes/Media/Movies` | `/Volumes/Media` | Included | Included |
| `/Volumes/Media` | `/Volumes/Media` | Included | Included |
| `/Volumes` | `/Volumes/Media` | Omitted | Included |
| `/` | `/Volumes/Media` | Omitted | Included |
| `/Volumes/Media2/Movies` | `/Volumes/Media` | Omitted | Omitted |

When only the ancestor source was watched, the callback returned before its
existing stream restart and invalidation steps. This is a deterministic policy
reproduction, not a claim that live FSEvents delivery or visible stale UI was
reproduced on this Linux host.

Apple documents the notification value as the volume's mount-path URL, and
specifically describes volumes mounting underneath monitored paths:

- [NSWorkspace volume path](https://developer.apple.com/documentation/appkit/nsworkspace/volumeurluserinfokey)
- [FSEvents mount-event semantics](https://developer.apple.com/la/documentation/coreservices/1455361-fseventstreameventflags/kfseventstreameventflagmount)

## Implementation and compatibility

`SourceVolumeChangePolicy.affectedRoots` tests ancestry in both directions using
standardized absolute paths. It handles `/` within this volume-selection helper
and respects component boundaries, so `Media2` is not a descendant of `Media`.
The original URL values, order, and duplicates are preserved. Selection does not
query storage, resolve symlinks, add watched roots, or modify saved history.

The existing callback still restarts its stream and emits `.rootChanged` for
each affected source. The existing broad-root rescan policy is retained. If
`/Volumes` is selected, its rescan can encompass other volumes too; the promise
that a sibling remains unaffected applies when it is watched without an
affected ancestor. This is not an optimization or a new scan-budget policy.

The dedicated runner copies actual source and tests unchanged. On macOS it also
compiles the real FSEvents adapter and logging dependency and runs two additional
integration test definitions for selection -> rootChanged -> invalidation-plan
routing. It conditionally includes the separate planner file when present, so
it supports the independent extraction in PR #12 without copying that change.

## Executed validation

Environment: Linux x86_64, Swift 6.2.1, toolchain Swift Testing. This is not the
application's pinned Swift 6.3.2 dependency graph or a full macOS app build.

| Experiment | Result |
| --- | --- |
| Original callback predicate, new focused suite | 36 failed expectations |
| Candidate, debug, warnings as errors | 11 test definitions / 1 suite pass |
| Candidate, release, warnings as errors | 11 test definitions / 1 suite pass |
| Remove only ancestor matching | Rejected with 25 failed expectations |
| Remove path-component boundary protection | Rejected with 9 failed expectations |
| Native/test syntax parsing, shell syntax, YAML structure, diff whitespace | Pass |

The matrix checks 121 root/volume pairs against an independent path-component
ancestry oracle. Other tests cover exact/descendant compatibility, ancestor
sources, root paths, unrelated prefixes, empty input, nonexistent paths, dot
segments, Unicode, spaces, original URL retention, order, and duplicates.

Baseline provenance: `SourceFilesystemMonitor.swift` blob
`5d72b86349b8655e7188cd4f551ffd7816637abf` was verified before execution. A thin
static wrapper exposes its original `watchedRoots.filter` predicate verbatim;
it does not execute NSWorkspace or FSEvents on Linux. Candidate tests use the
production helper without source transformations or stubs. The earlier broader
PR's 21-test/root-planner results are not the evidence counts for this final diff.

```sh
bash Scripts/test-source-volume-regressions.sh --jobs 2 -Xswiftc -warnings-as-errors
bash Scripts/test-source-volume-regressions.sh -c release --jobs 2 -Xswiftc -warnings-as-errors
```

## Remaining qualification

The revised commit needs its own macOS CI result. Syntax parsing is not native
API type-checking. The two macOS integration definitions and native adapter
compilation were not executed locally. Neither the runner nor the new workflow
starts FSEvents, mounts disks, posts native workspace notifications, or launches
the application.

Before release, exercise a real mount/unmount/reconnect with `/Volumes` selected,
then a source inside that volume, and verify browser refresh and stream
reattachment. Check a similarly named sibling volume when watched alone. A
correct broad-root refresh can perform more work than ignoring an event, so
there is no CPU, energy, latency, or visible-playback improvement claim.

Saved-history corruption, moved-file identity, and active-playback recovery are
not claimed reproduced or fixed by this change. No other agent's PR was edited.
