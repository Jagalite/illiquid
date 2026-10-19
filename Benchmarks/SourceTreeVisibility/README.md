# Source-tree visibility benchmark

Measure the real background browser projection when visibility settings change
without changing the underlying source tree. The current baseline for native
qualification is consolidated `main` at
`33fff16155c3472960f88e04c72dfdfdefd56dcf`.

The original Linux measurements used
`68274d1b09dcc866296321a5a8858efc297c4f19` and remain historical evidence with
their original manifests. The retained baseline was refreshed on October 19,
2026 to include the media-name recognition and NFO parser changes subsequently
merged into `main`. Both variants in new runs use those same updated shared
dependencies. The source-browser filter and tree-input baseline implementations
are unchanged between the two revisions; new native measurements identify the
refreshed baseline independently of the original Linux cohort.

## Run

Swift 6.1 or later and Python 3 are required. Use macOS 26 and the repository's
pinned Xcode for native qualification. The isolated package uses Foundation and
the toolchain's Testing module; it does not resolve the native player SDK or
other remote packages. Production declarations are staged in an `IlliquidApp`
library target, and the benchmark driver is a separate executable target.
Both variants compile the library with `-enable-testing` so the driver can use
`@testable import` without changing production access levels. The test bundle
depends only on libraries; it never links the benchmark's command-line entry
point. This layout is required by the native release test-loader behavior
observed and retained in the first macOS attempt.

```sh
# Semantic tests for both variants in debug/release, plus the full timing matrix.
python3 Benchmarks/SourceTreeVisibility/run.py --output /tmp/source-tree-results

# Also reproduce the expected baseline cache-count failure.
python3 Benchmarks/SourceTreeVisibility/run.py \
  --tests-only --prove-baseline-failure --output /tmp/source-tree-tests

# Timing only, with six balanced AB/BA pairs at each size.
python3 Benchmarks/SourceTreeVisibility/run.py \
  --mode benchmark --samples 6 --sizes 100 1000 10000 \
  --output /tmp/source-tree-timings
```

Each output directory must be new or empty. `--swift` selects the compiler
driver. An exploratory smoke can use `--smoke --samples 1 --sizes 100`;
one-pair output is not the formal performance result. `--case` narrows the
workloads, and `--sizes 100000` enables a larger stress fixture.

## Workloads and timing boundary

| Case | Operation |
| --- | --- |
| `tree_rules` | Enable/disable a trailer-hiding regex in Tree mode. |
| `tree_show_hidden` | Toggle Show Hidden with 10% of files manually hidden. |
| `tree_manual_hide` | Add/remove a manually hidden path set. |
| `tree_always_show` | Add/remove Always Show overrides while a regex remains active. |
| `files_rules` | Enable/disable the regex in Files Only mode. |
| `media_rules` | Enable/disable the regex in Media mode. |
| `same_input_search` | Change only the search query. |
| `preview_only` | Toggle rule preview with unchanged visibility settings. |
| `cold_tree` | Project through a fresh filter actor. |
| `changed_sort` | Change the source sort direction. |

The fixture is a wide folder of deterministic, shuffled media entries. URLs,
timestamps, path identities, and recognized metadata are prepared outside
timing. Media recognition is prepopulated as it is by the normal metadata
loader; the baseline therefore does not receive an artificial penalty from
repeating recognition that normal loaded entries already contain.

Timing surrounds each awaited `SourceBrowserFilter.project(input:...)` call.
It includes the row building, visibility evaluation, path sets, and grouping
required by that call. Fixture construction, warmup, actor creation for the
cold control, output receipts, and cache-counter inspection are excluded.

Each baseline/candidate member runs in a fresh process. Process order alternates
AB and BA for an even number of at least six pairs. Both variants perform the
same even number of operations, alternating between the two setting states.
Summaries use each process's average call time and retain its individual call
durations, medians, ranges, and paired ratios. Separate diagnostic processes
record tree and visibility build counts.

These timings describe the background projection component. SwiftUI layout,
disk scans, complete visual response, and playback resource usage are outside
the measurement.

## Sources and verification

`baseline/manifest.json` records the current baseline revision, source Git blob IDs,
SHA-256 hashes, and extraction boundaries. The retained baseline consists of
complete small production files and guarded verbatim Foundation declarations
from `AppModel.swift` and `SourcesSidebar.swift`. The candidate stages the same
current declarations; all shared dependencies must match the baseline.

The benchmark executes the production actor, tree builder, matcher, sorter,
and model types. It does not substitute a simplified implementation. Linux
adapts the Darwin POSIX import to Glibc and adds the separate FoundationXML
import. The macOS sources retain their original platform imports.

On Linux, the staged copy of one existing sidecar test explicitly marks its
future temporary root as a directory. Without that hint, Linux Foundation
retains a file-style URL from before the directory is created, and the existing
reader's full-URL root comparison returns before reading the sidecar. This
baseline failure was reproduced before adding the guarded fixture adaptation.
Production code and the macOS test fixture are unchanged.

The runner executes the existing `SourceBrowserFilterTests` and
`SourceMediaOrganizationTests` plus `SourceTreeVisibilityCacheTests`. The new
cache-reuse assertion is excluded from baseline semantic test runs because it
deliberately detects the baseline's repeated tree builds. The optional
`--prove-baseline-failure` run verifies that it fails for the expected reason.

Every timed output is consumed after the timer and compared with the other
variant. Receipts contain a checksum covering every ordered row field and
annotation, thumbnail candidates, and the media-path set, plus counts. The
regression tests also compare full projection values against fresh actors, independently of
those checksums.

The compact `evidence/` output includes the raw observations, diagnostics,
summary, compiler/environment information, command/test logs, source and binary
hashes, and a compressed copy of the staged source packages. Generated builds
and compiler caches stay outside that directory.

See the [research report](../../Documentation/SOURCE_TREE_VISIBILITY_PERFORMANCE.md)
for findings and qualification status.

Retained observations and qualification receipts are under
[`Documentation/PerformanceEvidence/SourceTreeVisibility`](../../Documentation/PerformanceEvidence/SourceTreeVisibility).
