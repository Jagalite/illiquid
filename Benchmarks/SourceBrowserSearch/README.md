# Source-browser search performance

This benchmark compares the complete `SourceBrowserFilter.search` method at
main revision `68274d1b09dcc866296321a5a8858efc297c4f19` with the working-tree
implementation. It also measures cached actor `project` calls, which include
result projection, standardized media paths, and thumbnail-candidate collection.

The production change replaces the temporary flattened ID array with a reserved
set populated by direct insertion and union. Matching, cancellation checks, URL
normalization, visibility evaluation, media grouping, and final row ordering are
the existing production code.

## Reproduce

Requirements: Python 3.10+, Git containing the pinned baseline commit, and Swift
6.1 or later with its bundled Testing module. The native CI uses the project's
macOS 26 / Xcode 26.6 environment. No external Swift packages are fetched.

Run the actual-source regression suite for both implementations and build modes:

```sh
for configuration in debug release; do
  python3 Scripts/test-source-browser-search.py \
    --configuration "$configuration" --baseline-ref \
    --output "/tmp/search-baseline-$configuration"
  python3 Scripts/test-source-browser-search.py \
    --configuration "$configuration" \
    --output "/tmp/search-candidate-$configuration"
done
```

Run six balanced AB/BA measurement pairs:

```sh
python3 Benchmarks/SourceBrowserSearch/run.py \
  --pairs 6 --target-ms 120 --output /tmp/source-search-timing
```

The output directory must be new or empty. `--swift /path/to/swift` selects a
toolchain; on Linux, `--cpu N` pins the runner and its children to an available
CPU. `--case search/100000/2/broad` selects one exact case; repeat that option to
select multiple cases. The complete predefined matrix is in `run.py`.

For a separate Linux/glibc allocation cohort:

```sh
python3 Benchmarks/SourceBrowserSearch/run.py \
  --allocations --pairs 2 --output /tmp/source-search-allocations
```

The allocation meter is the existing `NonDecodePerformance/allocmeter.c`. It
counts successful intercepted `malloc`, `calloc`, and `realloc` requests and
requested bytes during each operation. It does not measure live heap, peak
memory, resident memory, or every allocator API. Instrumented wall times are
not used as the performance timing cohort.

## What is measured

The constructed workloads contain 1,000–100,000 media rows. Tree fixtures have
two or eight ancestor levels, nested paths, corresponding folder rows in input
order, and 100 sibling media rows per branch. Eight levels are a stress control.
They are reproducible expanded-row workloads, not measurements of a typical
user's library. No files are read or created for these rows.

Cases include broad display-name matches, one percent matches, no matches,
whitespace-only queries, Unicode names, and recognized-media filename fallback.
The latter controls expose costs outside the changed set construction. Projection
cases prime the existing visibility cache before timing; query processing and
the resulting path/thumbnail projection remain inside timing. UI delivery,
SwiftUI rendering, physical typing, source-tree construction, filesystem I/O,
and media playback are outside the benchmark.

For each case, a one-operation calibration chooses the same iteration count for
both variants. Every pair alternates process order: AB, BA, AB, BA, AB, BA. Case
order is fixed. Fixture construction, the old-source oracle, warmup, complete
row equality checks, and stable output receipts are outside the timed region.
The small per-iteration result-consumption cost is included without subtraction.
Wall time and process CPU time are recorded separately.

Every process validates its complete final row array against the exact old
search method extracted from the pinned Git revision. Projection additionally
checks thumbnail candidates, media paths, counts, and visibility-cache reuse.
Paired stable fingerprints and checksums must agree. Behavioral regression tests
also use explicit expected fixtures and seeded comparison with the original
algorithm, including duplicate identities and cancellation.

## Source and evidence integrity

`Scripts/test-source-browser-search.py` stages complete production Filter/Input
and portable core files, plus verbatim portable declarations from the larger
AppModel/Sidebar files. There are no replacement model types or changed source
algorithms. A separate executable target calls the production module, preserving
the normal compilation boundary. Only the Filter file differs between variants;
the runner verifies the compiled source, harness, oracle, and manifest hashes.

The output retains environment and toolchain details, commands and build logs,
source and executable hashes, the exact staged source files, calibration data,
every timing/allocation record, and summaries. `completion.json` distinguishes a
finished matrix from a partial run. No observations are removed as outliers.
Summaries include separate medians and within-pair reductions; the ratio of two
separate medians need not equal the median of paired reductions.

The focused macOS workflow runs the same component tests and benchmark. The
repository's existing restoration workflow also compiles the complete app graph
and runs the native release test suite containing the new search tests.
