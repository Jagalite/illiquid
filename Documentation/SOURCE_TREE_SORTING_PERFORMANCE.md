# Source-browser sorting performance

## Outcome and scope

The source-browser sorter now sorts integer indices and prepares filename keys
once when date ordering is disabled. It preserves the original entries and every
existing sort rule. Against integrated `main` at
`68274d1b09dcc866296321a5a8858efc297c4f19`, the final Linux component study measured
21–41% lower service time for the 10,000-entry name-heavy workloads. Date/type
sorting also improved; tied-date/name fallback showed little improvement at
1,000 entries and a smaller improvement at 10,000.

The production change is confined to `SourceTreeSorting` in
`Sources/IlliquidApp/UI/SourcesSidebar.swift`. Its three callers are in
`SourceTreeProjectionInput.swift`: flat Files Only/Media rows, a single active
folder's children, and each expanded folder's sibling list. These sorts run on
the existing `SourceBrowserFilter` actor when its immutable input changes.
Query-only searches reuse the cached row projection, and explicit root files in
Tree view retain source order without using this sorter.

Before publication, the patch was applied to newer integrated `main`
`33fff16155c3472960f88e04c72dfdfdefd56dcf`. The sorter, entry, and configuration
declarations were unchanged upstream, and other browser updates were preserved.
The native paired comparison uses this newer baseline. The original measured
Linux source declarations and runner are archived with their evidence so the
two source contexts remain explicit.

**macOS qualification:** the PR's `Source tree sorting` workflow runs both the
paired component study and real application/browser integration tests. Native
results will be recorded after those jobs complete. Linux measurements below are
not a claim about the user's Mac or total application responsiveness.

## Why the change helps

The previous implementation sorted enumerated `(offset, SourceTreeEntry)` values.
An entry includes its URL, dates, visibility path, and optional recognized-media
metadata. On the measured Linux build, the entry stride is 240 bytes and the
enumerated record stride is 248 bytes. The new sorting elements are 8-byte integer
indices. Once those indices are ordered, the original entries are materialized
in that order. The public/internal entry representation is unchanged.

Name comparisons also previously retrieved both URLs' `lastPathComponent` on
every comparison. The candidate computes each filename once for a name-enabled,
date-disabled sort. Those strings live only for that call. Full paths are still
read only when the localized filename comparison ties.

When date ordering is enabled, date differences can settle every comparison
without consulting filenames. Preparing name keys then would add unnecessary
work, so the candidate retains lazy filename access in that configuration. A
private `@autoclosure` delays the entire name-comparison expression until the
name criterion is reached.

Arrays with fewer than two entries and configurations with every criterion off
return the existing array. Swift value semantics preserve later independent
mutation of the returned/input arrays.

These are changes to sorting work and transient data movement. The study does
not measure resident memory or claim a percentage reduction in player RAM.

## Final Linux measurements

Swift 6.3.2, x86-64 Ubuntu 24.04, Foundation locale `en_001`. The two revisions
were compiled as separate release executables from the actual source declarations
and real metadata type. Each case uses six pairs with alternating process order
and identical iteration counts. Fixture construction and two warmup sorts per
process are excluded; each timed call includes key preparation, sorting, result
materialization/destruction, and the same small observable checksum.

The following values are medians in milliseconds per complete sort of 10,000
entries. Negative changes mean less time.

| Workload | Baseline ms | Candidate ms | Change |
| --- | ---: | ---: | ---: |
| Shuffled names | 423.736 | 250.386 | −40.9% |
| Already sorted names | 23.708 | 18.789 | −20.7% |
| Reverse-sorted names | 23.912 | 18.716 | −21.7% |
| Repeated basenames in different folders | 692.647 | 543.695 | −21.5% |
| Mixed folders/media, type then name | 359.744 | 228.112 | −36.6% |
| Unique dates ascending, name fallback enabled | 22.733 | 15.236 | −33.0% |
| Unique dates descending, name fallback enabled | 21.509 | 19.090 | −11.2% |
| Type, tied/missing dates, then name | 237.847 | 223.754 | −5.9% |
| Date only | 29.591 | 13.904 | −53.0% |
| Type only | 20.700 | 7.516 | −63.7% |
| All criteria off | 2.555 | 0.086 | −96.6% |
| Names with populated recognized-media metadata | 621.110 | 407.631 | −34.4% |

At 1,000 entries, shuffled names improved from 43.625 to 26.820 ms (−38.5%) and
metadata-populated names from 54.239 to 37.038 ms (−31.7%). The tied-date/name
case changed from 14.903 to 14.953 ms (+0.3%), which is treated as unchanged.

Some observations have wide ranges. For example, the 10k duplicate-basename
candidate ranged from 479.20 to 701.07 ms, and the descending-date candidate
from 14.16 to 23.57 ms. These wall-time component medians do not establish a
tail-latency guarantee. All raw observations, medians, ranges, and per-pair
changes are retained in
[`Benchmarks/SourceTreeSorting/evidence/linux/`](../Benchmarks/SourceTreeSorting/evidence/linux/).

## Correctness and integration

The comparison retains this precise behavior:

1. Type precedes creation date, which precedes name.
2. Missing dates remain last in both date directions.
3. Natural filename order still uses Foundation `localizedStandardCompare`.
4. Equal natural names use literal full-path order in the selected direction.
5. Complete ties preserve original input order; disabled criteria do not add
   implicit ordering.
6. Each returned value is the original full entry, including recognition data.

The same 12 repository semantic tests passed against both revisions in debug
and release. They cover numeric order, precedence, nil dates, disabled keys,
Unicode collation/canonical equivalence, percent-encoded URLs, trailing folder
slashes, and stable duplicates with different metadata.

The independent differential harness checked 486 full output sequences (18
fixtures × all 27 configurations) in each build mode. It verifies entry count,
unique fixture identities, and full equality of every output entry to its
original. Before measuring each of the 48 size/workload combinations, it also
compares the complete output order and metadata of that exact fixture. These
full checks are outside the timed loop. Compressed correctness receipts, test
logs, source hashes, and environment details are retained with the Linux evidence.

Independent review found no ordering, lazy-evaluation, or benchmark-method
blocker. The production source, harness, and tests were checked against the
staged-source receipt before publication.

The macOS integration job builds the actual application/test dependency graph
using pinned native inputs and runs `SourceTreeSortingTests`,
`SourcesSidebarFolderModelTests`, `SourceBrowserFilterTests`,
`SourceMediaOrganizationTests`, and `SourceEmptyFolderVisibilityTests`. These
tests cover sorting consumers, filesystem listings, projection/cache reuse,
media grouping, visibility, and stable metadata. They do not exercise playback
with real media, physical displays, or user-machine GUI interaction.

## Reproduction and evidence

See [`Benchmarks/SourceTreeSorting/README.md`](../Benchmarks/SourceTreeSorting/README.md)
for commands, workload definitions, and the extraction/build procedure. The
runner requires the pinned baseline in Git history and never fetches dependencies
or overwrites an existing evidence directory.

The Linux run used a local Swift wrapper that adds
`--use-integrated-swift-driver` to SwiftPM build/test commands because the local
external driver crashed before compiling the baseline. This changes the build
driver, not the app sources or optimization configuration. macOS CI uses its
stock Xcode Swift invocation.

No whole-player CPU, energy, frame-rate, filesystem-discovery, or total sidebar
refresh benefit is inferred from these component measurements.
