# Source filesystem recovery audit

## Scope and baseline

Independent investigation of filesystem-event invalidation planning, based on
`main` at `8c3cc3d4008d5d1b8d436bcf2d51d891382b6548`. This does not extend the
playback-pipeline, filename-recognition, subtitle, or renderer-recovery PRs.
Changed-file lists for open PRs #5–#11 were checked before publication; none
intersect this patch. Unpublished work by other agents cannot be ruled out.

The retrieved baseline monitor and existing test file were verified against
Git blob IDs `5d72b86349b8655e7188cd4f551ffd7816637abf` and
`2ca3be6d4c8d736598939f78c161a0f04f49d3c9`, respectively. The container cannot
run AppKit/CoreServices, so local execution uses the actual Foundation-only
planner definitions, not a reimplementation or mocked FSEvents service.

## Confirmed defects

### Dropped-event recovery is incorrectly restricted by the marker path

With watched roots `/media/movies`, `/media/shows`, and
`/Volumes/External/Library`, a dropped-event marker inside the first root only
scheduled that root for rescan. A marker outside all roots scheduled nothing.
The unchanged source reproduced both results, including when the dropped flag
is combined with `mustScanSubdirectories` as in the native API contract.

Apple's [FSEvents programming guide, Handling Events](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html)
requires rescanning monitored directories after kernel/user event loss because
the missing changes cannot be inferred. Illiquid combines both native loss
flags into `SourceFilesystemEvent.Flags.eventsDropped`.

The fix recognizes event loss before path filtering and schedules every
normalized watched root. This full recovery supersedes targeted reload and
subtree-invalidation work in the same batch, regardless of event order.
Ordinary changes and path-local recovery without event loss retain their
previous scope. In particular, the existing event-ID-wrap policy is unchanged
apart from the root-path correction below.

### The filesystem root is not recognized as an ancestor

Both containment helpers appended `/` to the root unconditionally. For root
`/`, this produced a `//` prefix that did not match normal absolute paths.
Reproductions covered a watched filesystem root, recovery notifications at
`/` with watched descendants, active-root impact checks in both directions,
and pruning targeted work covered by a full rescan.

The fix uses `/` itself as the prefix at the filesystem root. Ordinary roots
still require a path-component boundary, so `/media/movies2` does not match
`/media/movies`. No filesystem resolution or case-folding policy is added.

## Implementation boundaries

The event/plan types and pure planner move to
`Sources/IlliquidApp/UI/SourceFilesystemInvalidationPlanner.swift`. Their
module, names, and visibility are unchanged. The stream-owning class and its
callback remain byte-for-byte unchanged after the extracted declarations.
The app target already discovers Swift sources in this directory.

No changes are made to stream creation, latency, stop/restart, mount observers,
callback scheduling, playback, media decoding, or cache ownership. The
portable runner copies the production planner and repository tests unchanged
into a temporary package and forwards normal `swift test` options.

## Tests and measurements

Local environment: Linux x86_64, Swift 6.2.1. Results are correctness evidence,
not a macOS application, UI, drive-reconnection, or performance measurement.

| Check | Result |
| --- | --- |
| New and existing tests against unchanged baseline definitions | 21 test methods; 47 failed expectations in 7 new methods; existing suite passes |
| Fixed planner, debug, warnings as errors | 21 test methods in 2 suites pass |
| Fixed planner, release, warnings as errors | 21 test methods in 2 suites pass |
| Exhaustive single-event matrix | 25,088 scenarios, all 256 internal flag combinations |
| Repeatable multi-event batches | 5,000 scenarios, including reversed-order comparisons |
| Direct baseline-parity comparisons outside the intended changes | 8,820 matches |
| Total differential/invariant assertions | 101,655; zero failures |
| Swift syntax parsing of changed source/test files, shell syntax, diff whitespace | Pass |

The 11 new test methods expand to 32 cases. They cover disjoint/nested roots,
loss markers inside/outside watched roots and at `/`, combined loss flags,
batch order, empty watches, normalized duplicate roots, ordinary old-root
events after root replacement, path-local recovery, Unicode paths, and
similarly prefixed sibling directories.

The broader harness uses a separate path-components-based containment oracle
and the exact baseline definitions for differential comparisons. Its flag
matrix intentionally includes combinations not expected from macOS; this is
robustness coverage, not a claim about their real-world frequency. The harness
and captured counts are in `Validation/SourceFilesystemRecovery`.

## Reproduce

From the PR checkout with the baseline commit available in Git history:

```sh
bash Scripts/test-source-filesystem-regressions.sh --jobs 2 -Xswiftc -warnings-as-errors
bash Scripts/test-source-filesystem-regressions.sh --jobs 2 --configuration release -Xswiftc -warnings-as-errors
bash Validation/SourceFilesystemRecovery/run.sh
```

For an offline/shallow checkout, the differential runner also accepts
`ILLIQUID_FILESYSTEM_BASELINE_FILE` pointing to an exported copy of the original
monitor. It verifies the same baseline Git blob ID before using that file.

A separate, path-filtered macOS workflow runs these checks using the repository's
existing Xcode/checkout pin. Other agents' workflows are not edited. Full native
qualification still requires the project's dependencies and this command:

```sh
swift test --force-resolved-versions --filter 'SourceFilesystemMonitorTests|SourceFilesystemRecoveryTests'
```

## Unconfirmed hypothesis and remaining risks

The earlier concern about queued callbacks surviving stop/restart is **not a
confirmed application defect**. Ordinary events from unrelated old roots are
already ignored by the planner; the new tests retain that behavior. This does
not prove native callback cancellation or validate a same-path replacement.
A deterministic native lifecycle test is still needed before changing stream
ownership or adding a generation token. No such fix is claimed here.

Full recovery may perform more I/O than the old path-limited response after an
event-loss notification. That is intentional correctness recovery, not a
performance optimization. The precheck adds a linear flag scan to ordinary
batches; no end-to-end performance claim is made. Live event-loss injection,
macOS callback delivery, mounted-drive changes, and visible library refresh
have not been exercised in this Linux environment. CI results must be checked
on the published commit; local results do not establish CI success.
