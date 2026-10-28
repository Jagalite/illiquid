# Flat file projection performance

## Scope

`SourceTreeProjectionInput.makeFlatFileRows()` merges recursively discovered
media with explicit file items before sorting and building display rows. The
baseline always normalizes every discovered URL and builds a temporary identity
set, even when a tab has only folder items and no explicit files to merge.

The candidate constructs that set only when an explicit file item exists. The
existing merge, sorting, final deduplication, recognition, and row construction
remain unchanged. This removes one linear normalization pass, its temporary
array, and its identity set from folder-only projections.

This affects rebuilding the **Files Only** and **Media** views after initial
discovery, source changes, or sorting changes. Search-only and visibility-only
updates can already reuse cached tree rows. No playback CPU, disk-scanning,
SwiftUI rendering, or end-to-end interaction improvement is inferred from this
component experiment.

## Reproduce

The current baseline is `070c7a4c84a4f00b2ac3e17587a7b5f3857952fd`. It adds the
source-preparation, media-grouping and filesystem-root sidebar and sidecar changes to the
original
`a2de305c8dbcaa81aac1477df7c9a0017c14eae3` baseline, preserving the strict
shared-source checks. The retained October 21 measurements keep their original
baseline and source manifests; they have not been rewritten.
Use the repository's macOS 26 / Xcode 26.6 environment for native qualification.
The isolated Swift package has no remote package dependencies.

```sh
python3 Benchmarks/FlatFileProjection/run.py --output /tmp/flat-projection-results

# Tests and exact output comparisons without timings:
python3 Benchmarks/FlatFileProjection/run.py \
  --mode verify --output /tmp/flat-projection-verification

# Exploratory smoke; this is not the final performance study:
python3 Benchmarks/FlatFileProjection/run.py \
  --quick --output /tmp/flat-projection-smoke
```

Output directories must be new or empty. `--swift` accepts a compiler path.
`--sizes`, `--cases`, and `--pairs` select workloads; the default study has six
balanced pairs for each of six scenarios at 100, 1,000, and 10,000 entries.
PR CI runs the tests and complete output comparisons in `verify` mode with
`--current-support`, as described below. Manual
workflow dispatch runs the full study with ten pairs and a 1,000 ms target per
observation. Timing results are research evidence, not a noisy pass/fail gate.

### Current integration context

Use this explicit mode when supporting production code has changed since the
pinned baseline:

```sh
python3 Benchmarks/FlatFileProjection/run.py --current-support \
  --mode verify --output /tmp/flat-projection-current-support
```

Only the baseline `SourceTreeProjectionInput.swift` comes from the pinned
revision. Both variants compile the same current snapshot of every supporting
file and declaration, including the recursive scanner used by the filesystem
regression tests. The existing equality gate still rejects any difference in
compiled support; the projection optimization remains the focal difference.

`sources.json` and `environment.json` identify the comparison mode and focal
baseline. Every production source records its own origin, revision, role, and
original/snapshot hashes. A working-tree source has `revision: null` and a
separate `worktree_head`; hashes identify its exact bytes without attributing
current support to the old baseline revision. Timings collected with current
support are a new integration-context experiment, not a reproduction of the
retained historical measurements.

The default CLI and the manual historical study remain strict: without
`--current-support`, changed shared dependencies are rejected. Run the historical
study from its recorded checkout. Existing evidence and retained baselines are
unchanged.

## Method

The runner uses the existing source-tree benchmark's guarded staging definitions.
It compiles the complete production projection input and supporting Foundation
declarations, with a separate executable driver. In the default strict mode,
baseline files come directly from the pinned Git revision; candidate files come
from the current checkout.
The runner rejects any staged production difference outside
`SourceTreeProjectionInput.swift`. There is no replacement projection or sorter.

Both variants run `SourceBrowserFilterTests`, `SourceMediaOrganizationTests`, and
`FlatFileProjectionTests` in debug and release. The new tests compare complete
rows across folder-only and mixed sources, loaded and missing explicit files,
duplicates, sorting directions, metadata precedence, Unicode and lexical aliases,
empty inputs, and pre-cancellation. Before timing, every fixture's complete row
trace must match between variants, including URL representation, recognition,
dates, visibility, context, and order.

| Scenario | Fixture |
| --- | --- |
| `folders-files` | Four folder roots, discovered media, Files Only view. |
| `folders-media` | The same roots with recognized metadata supplied by the loader. |
| `mixed-files` | Folder entries plus overlapping explicit files and five not-yet-discovered files. |
| `mixed-media` | The same transient merge fallback, with metadata already supplied for discovered entries. |
| `explicit-files` | Explicit files only, with an empty recursive inventory, as in the Files Only loader path. |
| `explicit-media` | Explicit files only, with metadata-loaded entries, as in the Media loader path. |

Fixtures use Unicode folder names, deterministic shuffled filenames, and
duplicate explicit items. Fixture preparation and metadata recognition happen
outside timing. Each observation uses a fresh process, two warmups, and the same
iteration count for both variants. Process order alternates AB/BA. Wall and
process CPU timers surround each complete `rows()` call; output consumption and
returned-row destruction happen afterward. Reported values are averages per
call in each process and medians across pairs. All observations are retained.

The output records source and executable hashes, compiler/host identity,
configuration, command logs, test counts, complete parity traces, calibration,
per-call durations, ranges, and paired changes. It checks staged source, driver,
and executable integrity again at completion. Linux support uses the existing
documented POSIX/XML imports and legacy test-directory hint adaptations; macOS
production source staging needs none.

## Results

The native study on Apple M1 (Virtual), macOS 26.6.2 and Apple Swift 6.3.3
measured lower median paired wall and CPU time in all six folder-only cells.
Both metrics improved in 32 of 36 target pairs.

| Files | Files Only wall reduction | Media wall reduction | Files Only CPU reduction | Media CPU reduction |
| ---: | ---: | ---: | ---: | ---: |
| 100 | 22.54% | 23.54% | 22.38% | 19.05% |
| 1,000 | 25.33% | 22.16% | 24.32% | 18.21% |
| 10,000 | 15.16% | 13.26% | 16.61% | 13.30% |

These percentages are medians of paired changes for complete `rows()` calls.
They are component results from one synthetic-workload host, not whole-player
or interactive-latency measurements.

The first short-batch cohort also showed substantial slowdowns in four control
cells. A targeted confirmation kept the sources and harness unchanged, increased
to ten pairs, and targeted 1,000 ms per observation. Those four median changes
were -3.76% to +1.67% wall and -3.51% to -0.16% CPU. The large initial control
slowdowns did not reproduce; individual observations remained variable. Both
cohorts, all controls and all samples are retained. This does not establish
exact equivalence, tight tail latency or a universal absence of regressions.

Correctness qualification passed all four baseline/candidate debug/release
runs (20 tests reported per run) and all 18 full-row comparisons. The confirmation
repeated four complete-output comparisons and retained 80 additional timed
observations alongside the initial 216. Independent audits reproduced the
source receipts, output comparisons, checksums, execution order and statistics.

See the [complete results and raw evidence](evidence/README.md), the
[initial native run](https://github.com/Jagalite/illiquid/actions/runs/39666994530),
and the [targeted confirmation](https://github.com/Jagalite/illiquid/actions/runs/39669135880).

## Sorted-entry storage follow-up

The index-storage study uses baseline
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72` to isolate a later change:
flat projection consumes the sorter's existing permutation directly instead of
materializing a complete sorted entry array before building display rows.
The ordinary `sorted` API and its comparator are preserved. With sorting disabled,
or fewer than two entries, projection keeps the original direct iteration path.

`--include-sorter` retains the baseline sorter as well as projection Input.
The runner permits only the exact `SourceTreeSorting` declaration to differ
inside the staged Sidebar values; all surrounding declarations must match.
`SourceTreeSortingTests` joins the existing three regression suites.

```sh
python3 Benchmarks/FlatFileProjection/run.py \
  --baseline ea2ff568237e2667f7b1aeee67b11a44ebe95b72 \
  --current-support --include-sorter --sizes 10000 --sorts name date off \
  --pairs 6 --target-ms 120 --output /tmp/flat-projection-index-timing

# Separate Linux/glibc cohort; these instrumented timings are not speed evidence.
python3 Benchmarks/FlatFileProjection/run.py \
  --baseline ea2ff568237e2667f7b1aeee67b11a44ebe95b72 \
  --current-support --include-sorter --sizes 10000 --sorts name date off \
  --mode benchmark --allocations --pairs 2 \
  --output /tmp/flat-projection-index-allocations
```

The six source/view scenarios run with ascending name order, descending creation
date order, and all sorting disabled. Complete row traces are compared for each
scenario and sort before measurement. Default CLI sort selection remains
`name`, so earlier study commands retain their workload selection.

The allocation cohort uses the existing `NonDecodePerformance/allocmeter.c`.
It records successful intercepted malloc/calloc/realloc requests and requested
bytes only during each complete production `rows()` call. It excludes fixture
setup, result consumption, and returned-row destruction. It does not measure
peak heap, live heap, all allocation APIs, or whole-player resident memory.
Allocation measurements use one call per process after two warmups; native
timings are collected separately without instrumentation. Every observation,
source hash, full-row trace hash, compiler identity, and completion marker is
retained.

The [index-storage research report](../../Documentation/FLAT_PROJECTION_INDEX_STORAGE.md)
records the completed allocation findings and the current native qualification status.
