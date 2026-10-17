# Filesystem event-loss recovery audit

## Scope and coordination

Independent audit of filesystem-event invalidation on `main` at
`8c3cc3d4008d5d1b8d436bcf2d51d891382b6548`. The final production change is
**seven added lines in `SourceFilesystemInvalidationPlanner.plan`**, currently
inside `Sources/IlliquidApp/UI/SourceFilesystemMonitor.swift`.

The initial investigation also reproduced incorrect `/` containment. A final
open-PR check found concurrent implementations in #12 and #17. Their root-path
fix, production extraction, and shared runner/workflow names were removed from
this PR; those changes belong to the other agents. This PR retains only the
independent dropped-event recovery fix, with uniquely named support files.

There is still one shared production file. If either extraction PR merges
first, relocate the seven-line precheck into its
`SourceFilesystemInvalidation.swift`, immediately after normalized roots are
created. Both portable runners support that layout, but a combined native
build has not been qualified. No other branch is modified by this work.

## Confirmed defect

For watched roots `/media/movies`, `/media/shows`, and
`/Volumes/External/Library`, a dropped-event marker inside the first root only
scheduled that root for rescan. A marker outside all watched roots scheduled
nothing. These results were reproduced with the original planner, including
loss combined with `mustScanSubdirectories`.

Apple's [FSEvents guide, Handling Events](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html)
requires rescanning monitored directories after kernel/user event loss because
the missing changes cannot be inferred. Illiquid combines both native loss
flags into `.eventsDropped`. Filtering by the loss marker's path first can
therefore leave unrelated watched folders stale.

The precheck handles loss before path filtering, returns all normalized watched
roots, and supersedes targeted work in the batch. Empty watches still produce
no work. Ordinary events, path-local recovery, containment, and native stream
ownership are unchanged. Event-ID-wrap policy is not redesigned here.

## Executed evidence

Environment: **Swift 6.2.1, Linux x86_64**, using toolchain Swift Testing rather
than the full app's pinned dependency graph. The original monitor and existing
tests were verified against Git blob IDs
`5d72b86349b8655e7188cd4f551ffd7816637abf` and
`2ca3be6d4c8d736598939f78c161a0f04f49d3c9`.

The temporary package extracts the exact Foundation-only production declarations
without altering their implementation and copies repository tests unchanged.
It neither mocks FSEvents nor compiles the native adapter on Linux.

| Check | Final narrowed result |
| --- | --- |
| Original planner with the final tests | 29 failed expectations; existing suite passes |
| Fixed planner, debug, warnings as errors | 17 methods / 2 suites pass |
| Fixed planner, release, warnings as errors | 17 methods / 2 suites pass |
| Exhaustive single-event matrix | 25,088 scenarios across all 256 internal flag combinations |
| Repeatable multi-event batches | 5,000 scenarios, including reversed-order comparisons |
| Baseline-parity comparisons outside loss/root-boundary cases | 8,820 matches |
| Total differential/invariant assertions | 60,650; zero failures |

Seven new test methods expand to 22 cases. Coverage includes disjoint roots,
loss markers inside/outside watches and at `/`, combined loss flags, batch
order, empty watches, duplicate normalized roots, and ordinary old-root events.
The broader harness checks recovery scope and exact plan parity, not native
notification delivery. Synthetic flag combinations are robustness coverage,
not a claim about their real-world frequency. Root-containment parity cases
are excluded so this harness does not duplicate or block #12/#17's changes.

## Reproduce

```sh
bash Scripts/test-filesystem-event-loss-regressions.sh --jobs 2 -Xswiftc -warnings-as-errors
bash Scripts/test-filesystem-event-loss-regressions.sh --jobs 2 --configuration release -Xswiftc -warnings-as-errors
bash Validation/SourceFilesystemEventLoss/run.sh
```

The differential runner uses the pinned baseline from Git history, or accepts
`ILLIQUID_FILESYSTEM_BASELINE_FILE` pointing to an offline exported monitor.
It rejects a baseline with the wrong Git blob ID. Results and the deterministic
harness are retained in `Validation/SourceFilesystemEventLoss`.

The dedicated macOS workflow uses the repository's existing Xcode/checkout
pins. Full native execution additionally requires the app dependencies:

```sh
swift test --force-resolved-versions --filter 'SourceFilesystemMonitorTests|SourceFilesystemEventLossTests'
```

## Limits and trade-offs

Live FSEvents loss, mounted-drive changes, callback delivery, UI refresh, and a
full macOS build were not exercised locally. Observe CI on the final commit;
local results do not establish macOS success. The earlier queued-callback
stop/restart hypothesis remains unconfirmed and is not fixed here. Ordinary
events from unrelated old roots are already filtered; that alone does not
prove callback cancellation or same-path replacement safety.

Recovery intentionally may perform more I/O after event loss. The extra
ordinary-batch flag scan is linear. This is a correctness fix, not a measured
CPU, energy, latency, or playback improvement. No merge or release is performed.
