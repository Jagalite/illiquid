# Source filesystem root invalidation audit

## Scope and provenance

Independent audit of folder discovery / source-library refresh, starting at
`8c3cc3d4008d5d1b8d436bcf2d51d891382b6548` on `main`. This does not extend the
playback-pipeline, subtitle-association, Unicode-date, or metadata-ID pull requests.
The visible open PRs and branch names were checked before selecting this work and
again before publication. Unpublished work in other agents' local environments is
not visible to this audit.

The original `Sources/IlliquidApp/UI/SourceFilesystemMonitor.swift` blob was
verified as `5d72b86349b8655e7188cd4f551ffd7816637abf`. The unchanged existing test
file, `Tests/IlliquidAppTests/SourceFilesystemMonitorTests.swift`, was verified as
`2ca3be6d4c8d736598939f78c161a0f04f49d3c9`. Focused source copies were used locally;
the complete native application was not built in this environment.

## Confirmed defect

Both the event planner and `SourceFilesystemInvalidationPlan.affectsAny` tested
containment using `path == rootPath || path.hasPrefix(rootPath + "/")`.
For filesystem root `/`, the descendant prefix becomes `//`.

Reproduced effects in the real production policy:

- With `/` selected as a source, creating, removing, or renaming a descendant
  media file yields an empty plan instead of reloading its containing folder.
- An ancestor-wide rescan event at `/` fails to reach ordinary nested source
  roots. The tests cover all four flags that request a full rescan: dropped
  events, wrapped event IDs, root changes, and must-scan-subdirectories.
- Impact detection misses both a descendant change affecting a `/` source and a
  `/` rescan affecting a nested active source.
- With overlapping `/` and nested roots, a broad rescan fails to remove redundant
  directory/tree invalidations in the same event batch.

These are deterministic policy reproductions, not a claim that native FSEvents
emitted every synthetic flag/path combination or that a live UI failure was seen.

## Implementation

Move the existing event value types and planner to the Foundation-only
`SourceFilesystemInvalidation.swift`. The native monitor, volume observers,
FSEvents callback, and raw flag conversion remain byte-for-byte unchanged.
No public API or module membership changes; the existing Swift package discovers
both files under `Sources/IlliquidApp` automatically.

Change only the two containment expressions in the extracted policy:

```swift
path == rootPath || path.hasPrefix(rootPath == "/" ? rootPath : rootPath + "/")
```

An ordinary root still requires a path-component boundary. `/Movies2` is not
inside `/Movies`, and `/Movie` is not its ancestor. Root matching is lexical, not
new filesystem I/O or symlink resolution. This uses the same root-prefix rule
already present in `SourceMediaPresenceScanner`.

The dedicated runner copies the actual production policy and both repository
Swift test files unchanged into a temporary package. There is no substitute
planner, mock filesystem, or player dependency in that package. A separate macOS
workflow exercises this runner in debug and release without editing the existing
restoration workflow used by other agents.

## Validation completed locally

Environment: Swift 6.2.1 (`swift-6.2.1-RELEASE`), x86_64 Linux.

| Check | Result |
| --- | --- |
| Baseline with existing and new tests | 20 test methods / 3 suites; 9 methods failed, 68 reported issues. All 10 existing methods passed. |
| Candidate debug, warnings as errors | All 20 test methods / 3 suites passed. |
| Candidate release, warnings as errors | All 20 test methods / 3 suites passed. |
| Event-policy translation invariant | All 6,144 cases passed in each candidate configuration. |
| Impact vs. path-component oracle | All 192 cases passed in each candidate configuration. |
| Native monitor / extracted policy / test syntax parsing | Passed; parsing is not native typechecking or execution. |
| Shell syntax, workflow YAML structure, diff whitespace | Passed. |

The translation invariant moves an entire absolute tree under `/scope`, then
checks that its plan moves identically. It covers all 256 combinations of the
eight event flags, six event paths, and four root sets, including overlapping
roots. It stops at the first counterexample on a failing implementation. The
separate impact oracle checks all three plan categories against path components,
including siblings, Unicode, spaces, and a literal percent sign.

Candidate commands from the PR checkout:

```sh
bash Scripts/test-source-filesystem-regressions.sh --jobs 2 -Xswiftc -warnings-as-errors
bash Scripts/test-source-filesystem-regressions.sh --configuration release --jobs 2 -Xswiftc -warnings-as-errors
```

To reproduce the baseline failure with the current tests (requires the baseline
commit in the local Git object database):

```sh
work="$(mktemp -d)"
mkdir -p "$work/Sources/IlliquidApp/UI" "$work/Tests/IlliquidAppTests" "$work/Scripts"
git show 8c3cc3d4008d5d1b8d436bcf2d51d891382b6548:Sources/IlliquidApp/UI/SourceFilesystemMonitor.swift > "$work/baseline.swift"
python3 - "$work" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
source = (root / "baseline.swift").read_text()
start = source.index("struct SourceFilesystemEvent:")
end = source.index("final class SourceFilesystemMonitor:")
(root / "Sources/IlliquidApp/UI/SourceFilesystemInvalidation.swift").write_text(
    "import Foundation\n\n" + source[start:end])
PY
cp Tests/IlliquidAppTests/SourceFilesystem{MonitorTests,RootRegressionTests}.swift "$work/Tests/IlliquidAppTests/"
cp Scripts/test-source-filesystem-regressions.sh "$work/Scripts/"
bash "$work/Scripts/test-source-filesystem-regressions.sh" --jobs 2 -Xswiftc -warnings-as-errors
# Expected: nonzero exit with the baseline failures described above.
# Remove the temporary $work directory after inspecting the result.
```

## Limits and remaining qualification

No cancellation defect was established in this pass. The inspected directory
scan already has cancellation checkpoints, and the presence scanner has a
generation guard before publishing worker results; those mechanisms were not
changed or fully stress-qualified here.

The new workflow needs to pass on macOS. The existing native-lifecycle workflow
should also build the application/test graph to qualify the source split. Native
FSEvents delivery, volume reconnects, rapid root replacement, visible sidebar
refresh, playback, energy, and release signing were not exercised locally.
No responsiveness or memory improvement is claimed.
