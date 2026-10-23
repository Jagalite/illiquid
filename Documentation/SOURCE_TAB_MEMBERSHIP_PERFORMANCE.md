# Source-tab membership performance

## Question and scope

Can the source-tab playing indicator avoid normalizing the same media URL for
every source item while preserving its existing membership rules?

The baseline is integrated `main` at
[`7f9ba073394b77a908e0589447c6edc8d10b832c`](https://github.com/Jagalite/illiquid/commit/7f9ba073394b77a908e0589447c6edc8d10b832c).
[`SourceSidebarTab`](../Sources/IlliquidApp/UI/SourceSidebarTabs.swift) asks
`AppModel.isCurrentMediaInsideSourceTab` whether to draw the playing indicator.
That main-actor call uses `SourceTabs.contains(_:in:)` in
[`AppModel.swift`](../Sources/IlliquidApp/App/AppModel.swift).
Tabs can contain files, folders, or both, including multiple files added through
the source picker or drag and drop. A tab containing a single folder is an
important control; the large fixtures represent tabs with many source entries,
not the number of descendants within one folder.

The old implementation visits items in order. Each file comparison calls
`NormalizedFileURL.representsSameFile`, which normalizes both the query and item.
Each folder comparison normalizes both URLs and constructs both component
arrays. The query is invariant throughout this scan. The scan runs when the
badge view is evaluated, not necessarily once per video frame.

This change is separate from the already integrated playlist lookup, source
sorting, search, visibility, thumbnail and filesystem-watcher work. It changes
only source-tab membership and adds focused qualification.

## Implementation and compatibility

The new method returns immediately for an empty tab and evaluates the first item
with its original predicate. A first-item hit or a singleton miss returns before
query-cache preparation. Only when the scan must continue does the method
normalize the query once for the remaining items and lazily obtain its path key
or path components. It still constructs and normalizes each item's URL and stops
at the first match.

For a supported local query visiting K >= 2 items, normalization calls fall from
2K to K + 2: two for the original first comparison, one query preparation, and
one per remaining item. A first-item result retains two calls, and an empty tab
retains zero. Repeated folder comparisons in the tail also share one query
component array. Complexity remains O(K); additional storage is bounded by one
query's normalized URL, path, and components and lasts only for this invocation.
Keeping the first predicate's work does not imply identical compiled cost; the controls
below measure that path separately.

Two compatibility details make it inappropriate to substitute raw path strings:

* `SourceTabItem` is Codable, so decoded paths can bypass its normalizing
  initializer. Dot segments, Unicode and relative or empty stored paths must
  retain the current item-side transformations.
* File and folder matching have different existing rules. File matching rejects
  unsupported file authorities, credentials and ports. Folder matching first
  requires `isFileURL` and then falls back to the standardized lexical URL when
  strict normalization fails. A rejected file identity may therefore still
  match a later folder entry. This optimization preserves that behavior.

Folder containment continues to compare path components, so a folder named
`Shows` does not contain a sibling named `Shows-Archive`. Unicode normalization,
local-authority checks, relative bases, scan order, and lexical symlink identity
remain governed by the same Foundation calls and `NormalizedFileURL` helper.
There is no stored index or cache to invalidate between queries or tab changes.

Apple documents [`URL.standardized`](https://developer.apple.com/documentation/foundation/url/standardized)
as resolving dot segments in a URL; filesystem symlink resolution is a separate
[`resolvingSymlinksInPath()`](https://developer.apple.com/documentation/foundation/url/resolvingsymlinksinpath())
operation. This lookup continues to use the existing lexical helper.

## Qualification method

[`Benchmarks/SourceTabMembership`](../Benchmarks/SourceTabMembership/README.md)
contains the reproducible runner, frozen baseline, source hashes and driver.
Both variants compile the real `SourceTabItem`, `SourceTab`, supporting values,
and `SourceTabs` declarations extracted verbatim from `AppModel.swift`, plus the
unchanged `NormalizedFileURL.swift`. The extracted declarations form an
`IlliquidApp` module separate from `IlliquidCore` and the benchmark driver;
there are no substitute models or rewritten candidate predicates.

The same new regression suite runs on the baseline and candidate in debug and
release. Ten test functions include 1,512 comparisons in the URL/tab corpus, plus explicit
cases for local/unsupported authorities, Unicode, relative references, decoded
noncanonical paths, root and sibling boundaries, mixed item order, subsequent
tab mutations, empty and first/last-match cases, and lexical symlink identity.

The driver also compares exact serialized source items, query/base-URL receipts
and all 16 Boolean outputs for each of 22 workloads. The measured production
method is in a separately compiled, non-inlinable module, and every batch writes
results and contributes to an observable checksum. Fixture construction, URL
decoding, oracle evaluation, warmup and JSON output are outside the timer.
Per-lookup figures include the query loop, Boolean stores, checksum and timer
overhead; no empty-loop cost is subtracted.

The native qualification uses eight balanced AB/BA pairs in fresh processes,
rotates workload order between pairs, and calibrates each variant toward 60 ms
per sample. A minimum of one 16-query batch can exceed that target for expensive
cases. The runner retains all 352 timed observations. Wall time uses `DispatchTime`;
CPU time uses `CLOCK_PROCESS_CPUTIME_ID`. Reported reduction is the median of
the eight paired `100 * (1 - candidate / baseline)` values. Absolute medians
are calculated independently and may not reproduce the paired percentage.

## Results

### Refined native candidate

The final source revision is
[`9091a5b64091b9faea3e97517566bd603e42fcf7`](https://github.com/Jagalite/illiquid/commit/9091a5b64091b9faea3e97517566bd603e42fcf7).
The [native qualification](https://github.com/Jagalite/illiquid/actions/runs/39846409311)
uses macOS 26.6.2 on arm64, Apple Swift 6.3.3, and Xcode 26.6.

All four baseline/candidate debug/release test configurations and all 22 exact
fixture comparisons passed. The eight 64/1,000-entry last-hit/miss workloads
reduced paired CPU time by **35.5–51.6%**, with every CPU pair improving for each
workload. Mixed, Unicode/relative and decoded-path cases also improved in all
eight CPU pairs. [Complete refined evidence](../Benchmarks/SourceTabMembership/evidence/macos-refined/)
retains all 352 observations.

Times below are independent wall medians in **µs per lookup**. Positive reduction
means faster; negative means slower. Percentages are medians of paired ratios,
not ratios of the independent median columns.

| Workload | Baseline µs | Candidate µs | Paired wall reduction | Paired CPU reduction | Faster CPU pairs |
|---|---:|---:|---:|---:|---:|
| `empty` | 0.033 | 0.039 | -19.5% | -18.8% | 0/8 |
| `files-1-hit` | 11.859 | 13.542 | -12.0% | -11.7% | 2/8 |
| `files-1-miss` | 15.247 | 14.673 | -5.9% | +1.1% | 5/8 |
| `folders-1-hit` | 15.172 | 14.975 | +7.0% | +6.7% | 5/8 |
| `folders-1-miss` | 13.786 | 16.313 | -16.0% | -16.1% | 2/8 |
| `files-64-last` | 879.686 | 447.599 | +48.1% | +48.5% | 8/8 |
| `files-64-miss` | 867.259 | 540.458 | +36.4% | +36.7% | 8/8 |
| `folders-64-last` | 1,023.224 | 537.663 | +47.4% | +50.0% | 8/8 |
| `folders-64-miss` | 1,069.401 | 650.834 | +34.7% | +35.5% | 8/8 |
| `files-1000-last` | 12,934.422 | 7,858.831 | +39.0% | +43.3% | 8/8 |
| `files-1000-miss` | 13,968.618 | 8,023.479 | +48.3% | +48.3% | 8/8 |
| `folders-1000-last` | 14,512.370 | 7,102.465 | +49.8% | +51.6% | 8/8 |
| `folders-1000-miss` | 15,857.280 | 8,311.682 | +48.3% | +45.6% | 8/8 |
| `files-1000-first` | 12.943 | 12.979 | -0.3% | -0.1% | 4/8 |
| `folders-1000-first` | 17.911 | 17.780 | +0.2% | -0.4% | 4/8 |
| `mixed-128` | 1,331.366 | 764.131 | +47.4% | +47.3% | 8/8 |
| `unicode-relative-64` | 1,279.458 | 677.169 | +47.1% | +44.3% | 8/8 |
| `decoded-noncanonical-64` | 1,269.446 | 783.293 | +41.7% | +42.3% | 8/8 |
| `nonfile-files-64` | 76.989 | 2.897 | +96.5% | +96.5% | 8/8 |
| `nonfile-folders-64` | 70.004 | 74.310 | -2.2% | -2.8% | 4/8 |
| `unsupported-files-64` | 110.940 | 4.851 | +95.8% | +95.9% | 8/8 |
| `unsupported-folders-64` | 955.726 | 683.895 | +33.5% | +36.4% | 7/8 |

The first-hit controls in 1,000-entry tabs are close to neutral in this run
(−0.12% file and −0.44% folder paired CPU reductions, four of eight pairs faster
each). **The refinement did not demonstrate singleton neutrality.** Folder
singleton misses still measured 16.1% slower in paired CPU time (about 1.94 µs
additional CPU and 1.92 µs wall), and file singleton hits 11.7% slower (about
1.12 µs CPU and 1.25 µs wall); both were slower in six of eight CPU pairs. Empty
calls added about 6.3 ns CPU and 6.9 ns wall, with all eight pairs slower.

The calibration records expose a limitation for these short controls. The
folder-singleton-miss baseline pilot measured 34.86 µs wall per lookup and chose
108 batches, versus 285 for the candidate. Actual baseline samples lasted only
18–33 ms, versus 51–126 ms for the candidate. Different durations can interact
with CPU frequency or process settling; per-lookup normalization does not remove
those effects. The file-singleton-hit counts were closer (420 versus 385), so
unequal duration alone cannot explain every result. The large-scan benefit is
consistent, but these controls do not establish the size or cause of a stable
common-path regression.

### Supplementary fixed-count diagnostic status

At report publication on 2026-10-22, the [supplementary native run](https://github.com/Jagalite/illiquid/actions/runs/39848009670)
had not completed. Its pending result is not part of the
completed qualification above; singleton performance remains an unresolved
tradeoff.

The workflow reuses the unchanged production code and its verified release
binaries. It adds six short-path workloads with exactly 2,048 batches (32,768
lookups) per sample, eight balanced pairs, and independent baseline-versus-baseline
comparisons alongside baseline-versus-candidate comparisons. The workflow retains all 192 observations
in its evidence, with no outlier removal or subtraction of
the same-binary percentages from the candidate results. The purpose is to
measure variability and remove the unequal-iteration-count confound. A local
two-pair execution check verified the diagnostic's outputs and calculations;
that smoke check is not native timing evidence.

### Initial candidate and reason for refinement

The first implementation prepared reusable query data before examining any
nonempty tab. Its [native run](https://github.com/Jagalite/illiquid/actions/runs/39844712944)
measured commit `4a0d2976387451fd8991aef0869d58bc0d140f11` in the same native
environment. All baseline/candidate debug/release tests and exact benchmark
receipts passed. The 64/1,000-item last-hit/miss, mixed, Unicode/relative and
decoded-path workloads reduced paired CPU time by 39.7–55.1%; all eight CPU
pairs improved in each of those workloads.

That run also revealed a common-path tradeoff: the singleton-folder miss had
15.096 and 16.310 µs independent wall medians, a 16.2% paired wall regression
and a 15.4% paired CPU regression. Its paired additional wall time was about
1.94 µs. First-hit controls were mixed, and empty calls added about 4.45 ns
paired wall time. These unfavorable observations motivated preserving the first
item's original predicate before preparing query data for a longer scan. The
refinement adds one query normalization to long scans compared with the first
candidate, a deliberate tradeoff to avoid query-cache preparation on short paths.
The full [initial evidence](../Benchmarks/SourceTabMembership/evidence/macos-initial/)
is retained without filtering.

### Preliminary Linux smoke

The [Linux cohort](../Benchmarks/SourceTabMembership/evidence/linux-smoke/) is a
two-pair, 20 ms smoke qualification of the initial implementation, not the native
performance conclusion or a timing claim for the refined version. It passed all
four baseline/candidate test configurations and the 22-workload exact comparison.
Large file/folder scans used roughly 40–56% less wall time. The single-folder hit
measured 13.224→14.191 µs (7.1% slower by the paired estimator), and the first-folder
hit in a 1,000-entry tab measured 13.464→14.548 µs (8.2% slower). These are specific
hit controls; the singleton folder miss improved in the same cohort. No samples
are discarded because they are unfavorable. The refined implementation also
passed a fresh Linux debug/release test and exact-fixture qualification.

## Practical limits

The measured benefit applies to the in-memory membership calculation for tabs
with multiple source entries. A tab containing one folder does not scan all the
files inside that folder here. The benchmark therefore does not imply a benefit
proportional to the size of a folder's media library.

These measurements do not establish whole-player CPU, energy, decoding,
rendering, filesystem-scan, or SwiftUI frame-time improvements. The expected UI
benefit is less synchronous work when the badge is evaluated for a large source
tab; quantifying end-to-end responsiveness would require an application trace.
The fixtures do not establish the smallest tab size that benefits, or the
distribution of tab sizes in real use.
The PR's existing native integration workflow separately builds the application
graph and runs the complete release test suite. That full-application gate is
separate from the passing component qualifications recorded here; its current
status is visible in the PR checks.
