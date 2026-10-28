# Recursive source visibility: bounded ancestor reuse

Recursive Files Only and Media projections evaluate each file and every parent
up to its selected source root. Siblings repeatedly construct the same parent
URLs and run the same regular expressions. The candidate retains one parent's
ancestor evaluation for the duration of one visibility projection.

The mutable evaluator is a value bound to an immutable matcher snapshot. It
always evaluates the file itself, checks the parent and root with exact UTF-8
equality, preserves the nearest hidden ancestor and ordered regex matches, and
does not cache a cancelled evaluation. Immediate-root rows use the existing root
cache. Memory does not grow with directory count. Tree mode keeps the existing
direct-evaluation path.

## Reproduce

Requires Swift 6.3.2+ and Python 3. The component uses Foundation and the
toolchain's Testing module. It needs no FFmpeg, libass, application launch, or
remote Swift package resolution.

```sh
python3 Benchmarks/SourceVisibilityAncestors/run.py \
  --pairs 6 --target-ms 120 --output /tmp/visibility-ancestors
```

Use a fresh output directory and a checkout containing baseline Git history.
For a shallow checkout, fetch that history first. Select an existing compiler
with `--swift`. Submit the command through Kyoto when available, as required by
`AGENTS.md`; ephemeral CI reports its absence and builds serially.
`--mode test` runs only regressions; `--mode benchmark` does not qualify tests.
A narrowed `--case` or `--sizes` run is a separate cohort, recorded in receipts.

## Comparison

The baseline is main at `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`.
Both variants compile actual production `SourceBrowserFilter`, source-tree
input, matcher, builder, sorter, and supporting core types in a separate
`IlliquidApp` library. Only `SourceBrowserFilter.swift` and the guarded
`SourcesSidebar.swift` declaration slice differ. Every other staged dependency
must match byte-for-byte. Full original/extracted source hashes, Git blob IDs,
exact compiled snapshots, compiler/image information, build commands, and
executable hashes are retained and rechecked after measurement.

The stager follows the existing SourceTreeVisibility harness. Linux changes only
the platform POSIX/XML imports and one existing sidecar test's temporary-directory
URL hint; those adaptations are recorded. Production files stay untouched.

Existing browser/filter, media-organization, and tree-visibility-cache suites run
in debug and release for both variants. The eight new ancestor regressions run
against the candidate in both configurations. JUnit receipts must contain
executed, unskipped tests without failures, and all eight new test methods must
appear among completed cases.

## Workloads and timing

The ten workloads run at 100, 1,000, and 10,000 input files:

| Workload | Purpose |
| --- | --- |
| siblings_depth6 | A group of siblings below six ancestor levels. |
| groups_depth3 | Consecutive groups of 25 siblings below three levels. |
| interleaved_depth3 | Eight alternating parents; no adjacent cache reuse. |
| unique_parent_depth3 | A different parent for every file; bounded-storage control. |
| hidden_near | The nearest parent hides its descendants. |
| hidden_far | Hiding occurs at the outermost of six levels. |
| root_children | Files directly under the root, whose evaluation is already cached. |
| no_rules | Visibility-rule evaluation is bypassed. |
| tree_direct | Tree mode retains its direct matcher path. |
| media_depth3 | Recursive visibility plus the real media-grouping projection. |

Fixtures are synthetic lexical paths. Metadata recognition, URLs, timestamps,
and normalized identities are prepared before timing. Sorting is off to preserve
the authored grouped/interleaved order. Each projection alternates Show Hidden,
forcing visibility work while retaining the unchanged tree. Diagnostic runs
must report one tree build and three visibility builds for the initial call and
two toggles.

The timer surrounds the complete awaited production projection. Both monotonic
wall time and process CPU are recorded. Output consumption/checksums are outside
the timer. Receipts cover every ordered row field and annotation, thumbnails,
media paths, hidden counts, and rule counts through a stable complete-field
digest plus explicit counts. Direct semantic assertions are supplied by the
regression suites; these digests are not serialized field-by-field traces.

Six fresh-process baseline/candidate pairs alternate AB/BA. Each cell calibrates
one even iteration count used by both implementations. The faster variant aims
for at least 120 ms accumulated CPU/wall time; every timed observation must
exceed 40 ms on both clocks. Short observations remain in evidence and fail
qualification. No observations are discarded and no control is subtracted.

The default matrix contains 360 timed observations. Completion records identify
the exact requested cases/sizes, expected and actual counts, duration gates,
test mode, and final source/binary verification. Raw measurements, calibration
pilots, diagnostics, test receipts, source packages, and paired ratios remain
available in the uploaded evidence.

## Limits

Results measure background projection CPU and time for the stated synthetic
directory/rule shapes. They exclude disk scanning, SwiftUI/AppKit layout, user
typing latency, playback, energy, and whole-player memory. Cache-hit frequency
depends on source sorting and directory layout; interleaved and unique-parent
controls must be reported with grouped-sibling gains. Linux Foundation results
must remain distinct from the queued macOS qualification.
