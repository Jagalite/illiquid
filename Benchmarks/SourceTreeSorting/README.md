# Source browser sorting

This experiment reduces work in SourceTreeSorting.sorted while retaining the
existing type → creation date → natural filename order, literal full-path
tiebreaker, and stable original-entry order.

Baseline: 68274d1b09dcc866296321a5a8858efc297c4f19, after integration PR #33.

## Change and expected benefit

The old implementation sorts enumerated complete SourceTreeEntry values and
extracts filenames again for every name comparison. The candidate sorts integer
indices, maps back to the original entries once, and caches filenames lazily
within that one sort. Empty/single-entry and all-off requests return the input.
Type and date comparisons retain their original precedence and missing-date
rules. No persistent cache or invalidation state is introduced.

Lazy preparation matters: when creation dates decide the order, filenames are
never needed. An exploratory eager-cache variant regressed an eight-entry
unique-date case, so it was rejected.

The browser uses this sorter for recursive file views, active-folder contents,
and expanded folder children. Its actor already caches the completed projection:
query-only search changes reuse those rows. Expected benefits therefore concern
opening, refreshing, expanding, and reordering sources. These measurements do
not establish a whole-window latency or sustained playback CPU improvement.

## Reproduce

From a checkout containing the baseline commit and a Swift 6.1+ toolchain:

    python3 Benchmarks/SourceTreeSorting/run.py \
      --output /tmp/illiquid-sort-evidence --pairs 6 --target-ms 40

The output directory must be new or empty. The runner accepts --swift/--swiftc,
or SWIFT/SWIFTC environment variables. --mode test runs the contract tests only;
--mode benchmark runs the exact-output comparison and measurements.

The runner extracts the actual sort, configuration, entry, and
RecognizedMediaName declarations without rewriting them or replacing types.
Baseline and candidate are compiled separately from the same consumer harness
with optimization and whole-module optimization. The outputs include source,
test, harness, and binary hashes, compiler/OS/locale information, complete sorted
identity streams, test logs, raw paired timings, and a statistical summary.

Fixtures cover 27 configurations, eight layouts, six sizes, and four seeds,
plus every exact timed dataset: **5,205 full-order/payload comparisons**.
Layouts include missing/tied/unique dates, Unicode names, duplicate URLs, equal
basenames with distinct paths, populated media metadata, and long release names.
Eight independently written contract tests also run against both implementations
in debug and release.

Timings are warm component measurements: fixture creation and an initial warm-up
are outside the interval. Each sample repeatedly sorts the same prebuilt input,
consumes the returned array, and alternates baseline/candidate order across six
pairs. Full output equality is checked outside timing; the consumer is compiled
separately to prevent eliminating the sort. Reported reductions are medians of
the six paired ratios, which can differ from the ratio of the two median times.
Already-sorted, reversed, name-disabled, and all-off inputs are explicit controls.

The macOS workflow additionally installs the pinned native dependencies, builds
the app package graph, and runs the new tests plus existing browser projection,
directory-loader, and tri-state sorting regressions. Native exact-output parity
is required before treating the expanded experiment as qualified.

## Preliminary Linux evidence

Results/linux-preliminary.json and Results/linux-preliminary-measurements.jsonl
retain the first completed experiment and its exact source/harness receipts.
This earlier harness has 19 timed datasets and **3,907** full-output comparisons;
it predates the populated-metadata and long-filename additions. The production
sort and contract tests are identical to the current files.

Host: Linux x86_64, Swift 6.3.2, optimized build. Times include returned-array
consumption and destruction. These are not macOS or end-to-end app results.

| Input | Baseline median | Candidate median | Median paired reduction |
| --- | ---: | ---: | ---: |
| Default name sort, 8 entries | 0.0467 ms | 0.0330 ms | 30.4% |
| Default name sort, 32 entries | 0.7340 ms | 0.5109 ms | 29.3% |
| Default name sort, 128 entries | 5.3730 ms | 3.1733 ms | 38.9% |
| Default name sort, 1,000 entries | 53.4121 ms | 36.1158 ms | 36.6% |
| Default name sort, 10,000 entries | 516.6370 ms | 360.1564 ms | 31.3% |
| Already name-sorted, 10,000 entries | 41.1860 ms | 37.9369 ms | 3.7% |
| Equal basenames, 1,000 entries | 65.1227 ms | 50.2353 ms | 23.0% |
| Unique dates then name, 10,000 entries | 25.7867 ms | 15.8733 ms | 32.1% |

All eight contract tests passed for both source versions in debug and release.
The first experiment's 3,907 exact comparisons passed. Shared-host variation is
visible in the retained ranges; native results should take precedence.

## Observed Linux collation limitation

The expanded 5,205-case Linux run did **not** qualify: its long-name dataset
occasionally orders composed/decomposed accented names differently. Repeating
the identical baseline binary also changes this dataset's output. Thus the
failure cannot be attributed solely to the candidate, and it cannot be counted
as a passing candidate check.

LinuxCollationProbe.swift is a Foundation-only reproduction with no Illiquid
types. In eight processes, one process returned 8,000 contradictory forward/
reverse comparison pairs out of 10,000 for byte-identical inputs. The other
seven processes were stable. Literal full-path comparison remained stable.
Results/linux-collation-observation.json retains those observations.

Compile the diagnostic with swiftc -O LinuxCollationProbe.swift and execute the
binary in multiple fresh processes. This establishes an observed inconsistency
in this Linux runtime; it does not establish the precise Foundation/compiler
cause or whether another platform is affected.

The extended Unicode fixture and strict comparison gate remain enabled. There
is no normalization workaround, fixture exemption, or silent ordering tolerance.
The full expanded experiment must pass on native macOS before this change is
considered ready.
