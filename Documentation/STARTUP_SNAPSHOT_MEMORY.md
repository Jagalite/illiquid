# Startup source snapshot lifetime

## Finding

[`AppModel.historyStartup`](../Sources/IlliquidApp/App/AppModel.swift) was a permanent
static owner of a
[`ReadOnlyStartupLoader<StartupResources>`](../Sources/IlliquidApp/App/ReadOnlyStartupLoader.swift). The loader correctly coalesces the
scene and application-delegate startup requests and caches their read result.
That result contains the persistence store and the complete
`SourceStartupSnapshot`: source tabs, item path strings, and visibility rules.

After `loadShared()` published the live model, its startup loader still cached
the original source snapshot until application shutdown. Changes to the live
source list could therefore leave all the original source paths and backing
arrays retained. The extra owner also required copy-on-write when otherwise
uniquely owned source arrays were edited.

This is retained, still-reachable data rather than an unreachable allocation
leak. The cost grows with the saved source list and visibility configuration.
It is most visible after changing or removing a large restored source list.

## Change and lifetime guarantees

The startup loader now has an optional static owner. `loadShared()` clears that
owner immediately after assigning `sharedInstance`, before dispatching queued
open requests. The live model and player retain the resources they still need.
The original cached snapshot can be released once existing startup callers
finish.

The ordering is deliberate:

1. Both publication and owner retirement run on `MainActor`, with no suspension
   between them. A later caller returns the already-published model.
2. A caller already suspended in `load()` keeps the loader and its pending task
   alive. It receives the read result and then returns the same shared model
   through the existing post-await check.
3. Successful publication does **not** call `stop()`. Stopping at that point
   would suppress the result of an existing waiter before it can reach the
   shared-model check.
4. Shutdown first marks startup as disallowed, then stops any remaining loader
   and clears its owner. The existing post-await guard still prevents late
   model publication. A preferences read already running to completion retains
   its data until its active readers finish.

[`SourceRootIndexStore`](../Sources/IlliquidApp/App/SourceRootIndex.swift) and current
UI consumers can independently hold source
values. The change removes the permanent startup owner; it does not require
those legitimate consumers to release data before they have finished.

## Evidence and interpretation

The reproducible experiment is in
[`Benchmarks/StartupSnapshotLifetime`](../Benchmarks/StartupSnapshotLifetime/README.md).
It compares the startup block from baseline
`6f70cd2446fc6ef38d4e5a0fbf96f91b2234e635` with the current worktree block,
using the production loader and source value types. The subsequent base update
to `1bf90fe673a062d100070abde2d793fed77588d4` changes external subtitle
conversion and leaves these startup sources unchanged.

The experiment isolates startup ownership. Playback objects, diagnostics, and
the preferences read use small stubs; the live source array omits observation
and background index work. Measurements describe live allocator-accounted
bytes, not process RSS or whole-player memory. Allocators can retain freed
pages, so freeing the snapshot need not cause an equal immediate RSS drop.
Array storage identity checks demonstrate the extra startup owner in this
isolated workload; they do not establish the allocation cost of a real UI edit.

### Linux results

Swift 6.3.2, optimized builds, four alternating baseline/candidate pairs per
source count (16 fresh processes in total). The table reports median live
allocator bytes after removing the live source list, relative to the same
process before startup. The probe is `mallinfo2.uordblks + mallinfo2.hblkhd`.

| Restored file paths | Baseline retained delta | Candidate retained delta | Median paired reduction |
| --- | ---: | ---: | ---: |
| 1,000 | 230,064 B | 33,712 B | 196,352 B |
| 100,000 | 20,030,272 B | 33,712 B | 19,996,560 B (19.07 MiB) |

The remaining roughly 33 KiB includes component runtime/startup allocations;
it is not a retained source snapshot. At 100,000 paths the baseline releases
its extra storage only at shutdown. With the change, the source data is already
released after source removal.

For the isolated first-item replacement, the baseline added 24,144 B at 1,000
paths and 2,400,352 B at 100,000 paths. The candidate added no live allocator
bytes at that step. Both outer and item-array buffers were reused in all eight
candidate processes and in none of the baseline processes. These checks
identify the eliminated startup owner; real UI observation/index sharing can
still require copying.

All paired receipts matched source contents before and after the edit, one
startup read, one model construction, delivery of both queued open requests,
late-call shared-model identity, and rejection of loads after shutdown.
[Raw measurements](../Benchmarks/StartupSnapshotLifetime/evidence/linux/measurements.jsonl),
[summary](../Benchmarks/StartupSnapshotLifetime/evidence/linux/summary.json),
and [source/compiler manifest](../Benchmarks/StartupSnapshotLifetime/evidence/linux/manifest.json)
are committed with the experiment.

## Regression coverage

[`ReadOnlyStartupLoaderTests`](../Tests/IlliquidAppTests/ReadOnlyStartupLoaderTests.swift)
exercises the production loader with deterministic
read and caller-entry gates. It verifies one read for two callers, cached reads,
shutdown during a read, destruction of a cached reference payload when its
owner is released, and completion of both in-flight callers after retirement.
The stopped and successful in-flight cases both verify final destruction.

The lifetime tests use weak task captures and return only scalar counts from
their tasks. Completed task handles cannot accidentally retain the payload
under observation. There are four tests and five parameterized cases; both
debug and release passed under Swift 6.3.2 on Linux.

The portable runner compiles the unchanged production loader and the actual
test file without the native macOS application dependencies:

```sh
bash Scripts/test-startup-loader-regressions.sh --configuration debug --jobs 2
bash Scripts/test-startup-loader-regressions.sh --configuration release --jobs 2
python3 Benchmarks/StartupSnapshotLifetime/run.py --pairs 4 --output /tmp/startup-snapshot-memory
```

These loader tests also pass before the caller fix: they establish the
ownership and concurrency contract that permits retirement. The baseline vs.
candidate experiment exercises the changed production startup block.

The `Startup snapshot lifetime` GitHub Actions workflow repeats the component
checks and memory experiment on macOS, then builds the complete application
graph and runs `ReadOnlyStartupLoaderTests` and `SourceStartupSnapshotTests`
with the pinned native SDK. Native run results are linked from the PR.
