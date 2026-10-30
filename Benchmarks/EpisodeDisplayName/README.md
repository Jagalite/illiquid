# Episode display-name formatting

## Result

The recovered **Linux x86_64 / Swift 6.3.2** component campaign completed all
**360 fresh observations: 12 balanced pairs for each of 15 workloads**. Numeric
label workloads improved in all 12 pairs. This supports the small formatting
change; it does not establish faster full-library recognition or macOS UI
performance. Native macOS results are not part of this retained evidence; see
the linked workflow for the current qualification status.

Times below are median process CPU microseconds per label, including the
benchmark's common array/checksum/cleanup work. Reduction is the median of
matched-pair reductions, so it need not equal the ratio of the two marginal
medians. Intervals are descriptive paired-bootstrap 95% intervals.

| Workload | Original µs/label | Changed µs/label | Paired CPU reduction | 95% interval | Faster pairs |
| --- | ---: | ---: | ---: | ---: | ---: |
| Numeric episode | 1.844 | 0.198 | +88.87% | [+87.60%, +89.58%] | 12/12 |
| Episode range | 3.455 | 0.220 | +93.13% | [+92.46%, +94.23%] | 12/12 |
| Episode with title | 1.971 | 0.317 | +83.53% | [+79.46%, +86.47%] | 12/12 |
| Long Unicode title | 2.722 | 0.353 | +86.31% | [+84.12%, +87.83%] | 12/12 |
| Mixed library, 128 labels | 1.392 | 0.200 | +84.62% | [+82.20%, +88.27%] | 12/12 |
| Mixed library, 1,024 labels | 1.481 | 0.201 | +84.59% | [+83.94%, +87.54%] | 12/12 |
| Movie label control | 0.170 | 0.165 | +5.44% | [-0.60%, +12.01%] | 9/12 |
| Air-date label control | 0.139 | 0.126 | +7.15% | [-0.94%, +16.06%] | 9/12 |
| Unknown/extra control | 0.164 | 0.167 | -3.21% | [-9.71%, +6.14%] | 4/12 |
| Negative-number fallback | 2.566 | 2.404 | +2.00% | [-10.31%, +10.97%] | 7/12 |
| Wide-integer fallback | 2.618 | 2.446 | +4.77% | [-3.25%, +14.14%] | 8/12 |
| Large positive Int32 | 3.573 | 0.482 | +86.89% | [+82.99%, +89.59%] | 12/12 |
| Recognize + episode label | 36.567 | 34.583 | +4.94% | [-17.31%, +16.69%] | 7/12 |
| Recognize + mixed labels | 29.124 | 30.865 | -4.88% | [-20.82%, +14.80%] | 6/12 |
| Recognize + movie control | 17.267 | 16.372 | +10.19% | [+0.98%, +18.91%] | 9/12 |

Ordinary numeric labels fell from **1.844 to 0.198 µs per label**; ranges fell
from **3.455 to 0.220 µs**. The 1,024-label mixed batch fell from **1.517 to
0.206 ms** of component CPU time. Wall-clock reductions for these workloads
were similar; all CPU and wall summaries are retained in
[`evidence/linux-x86_64/summary.json`](evidence/linux-x86_64/summary.json).

The larger recognition paths were inconclusive: episode recognition plus its
label had a +4.94% paired median with an interval spanning −17.31% to +16.69%;
the mixed path had an adverse −4.88% median with an interval spanning −20.82%
to +14.80%. Even the unaffected movie-recognition control shifted +10.19%
([+0.98%, +18.91%]), so small changes here cannot be cleanly attributed to the
formatter. The unknown/extra label control also had an adverse −3.21% median.
The other label-control intervals crossed zero. These observations are retained;
the study does not establish equivalence or general non-regression of every
larger workload. No additional timing campaign was selected to replace them.

## Problem and production scope

[`RecognizedMediaName.displayName`](../../Sources/IlliquidCore/MediaLibrary/MediaNameRecognition.swift)
formats numeric TV labels such as `S02E18–E19 · Finale`. The previous
implementation calls Foundation's general-purpose `String(format:)` for every
season/episode pair and again for an optional range endpoint. The ordinary
nonnegative integer labels need only decimal conversion and a minimum width of
two digits.

This work applies to media-view library row construction. The production path is:

1. `SourcesSidebar.synchronizeRecursiveMediaScan` and
   `SourceRecursiveMediaLoader.read` in
   [`SourcesSidebar.swift`](../../Sources/IlliquidApp/UI/SourcesSidebar.swift)
   prepare entries for media view. Metadata-enabled scans retain each recognized
   value in `SourceTreeEntry.recognizedMedia` after calling
   [`MediaSidecarReader.recognize`](../../Sources/IlliquidCore/MediaLibrary/MediaSidecarReader.swift).
2. [`SourceTreeProjectionInput.makeFlatFileRows()`](../../Sources/IlliquidApp/UI/SourceTreeProjectionInput.swift)
   uses that retained recognition, or calls the filename recognizer when it is
   absent, and stores `recognition.displayName` in `SourceTreeDisplayRow`.
3. [`SourceBrowserFilter.project(input:...)`](../../Sources/IlliquidApp/UI/SourceBrowserFilter.swift)
   performs row construction on its existing background actor. The sidebar
   passes the resulting stored string to `SourceFileRow` for presentation.

Recognized values and row strings already have caches: the scan entries retain
recognition, and `SourceBrowserFilter.cachedRows` reuses rows when
`SourceTreeProjectionInput.hasSameTree(as:)` succeeds. Search and visibility-only
updates can therefore reuse the labels. The affected work occurs when media
rows are built or rebuilt; it is not repeated for every UI redraw or playback
frame. This change adds no cache or longer-lived storage.

## Change and compatibility boundary

The production change is confined to `RecognizedMediaName`. `displayName` calls
a private `episodeNumber(season:episode:lastEpisode:)` helper for numeric
episodes. When every present number is in `0...Int32.max`, the helper uses
`String(value)` and adds a leading zero for values below ten. Larger positive
numbers retain their complete decimal representation; two digits is a minimum
width, not a truncation limit.

If any component is negative or wider than a positive signed 32-bit integer,
the helper executes the complete original formatter expression. The `%d`
conversion has different behavior from ordinary Swift `Int` interpolation for
wide integers, so replacing it unconditionally would change existing labels.
The all-components guard also preserves the original number of formatter calls
on the fallback path.

The fallback protects a reachable public input domain. The filename patterns
and the NFO/PlexMatch parsers bound normal seasons and episode numbers, but
[`MediaMetadataHints`](../../Sources/IlliquidCore/MediaLibrary/MediaMetadataHints.swift)
has public mutable `Int?` fields. Public `RecognizedMediaName.applying(_:)` can
apply those values without the parser bounds.

The surrounding behavior is preserved:

- A non-nil `airDate`, including an empty string, overrides all number and range
  formatting through the existing nil-coalescing expression.
- Missing season or episode numbers become zero.
- Present range endpoints are displayed even when equal to or lower than the
  first episode; display formatting does not add validation.
- The en dash, middle-dot title separator, and exact title bytes remain intact.
  An empty episode title still adds the existing separator.
- Movies, extras, and unknown entries return `seriesTitle` as before.

The baseline is the complete production source at
[`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`](https://github.com/Jagalite/illiquid/commit/ea2ff568237e2667f7b1aeee67b11a44ebe95b72).
Its frozen copy and file/test hashes are retained in
[`baseline/manifest.json`](baseline/manifest.json). The initial candidate source
and harness revision is
[`84fac120681a7e52db779c2153c6b9b015975e0f`](https://github.com/Jagalite/illiquid/commit/84fac120681a7e52db779c2153c6b9b015975e0f).
Each study records the actual checkout and hashes of every compiled input.

## Correctness qualification

[`EpisodeDisplayNameTests.swift`](../../Tests/IlliquidCoreTests/EpisodeDisplayNameTests.swift)
adds eight test methods. They cover explicit minimum-width labels, nil values,
same/reversed ranges, empty and arbitrary dates, all non-episode kinds, and
Unicode/empty/nil episode titles. Output comparisons use UTF-8 bytes so canonical
Unicode equivalence cannot hide a changed spelling.

The generated coverage includes 30,000 per-component comparisons for values
`0...9999`, 4,096 deterministic positive Int32 samples plus the maximum value,
and 750 negative/wide-integer combinations. The latter include `Int.min`,
`Int.max`, signed 32-bit boundaries, and values around multiples of 2^32. The
reference expression is the previous complete `displayName` implementation.

[`run.py`](run.py) compiles the complete frozen and candidate production files
in separate isolated packages. It runs the same new tests plus three unchanged,
hash-checked recognition suites against both variants in debug and release,
with warnings treated as errors. It also compares the driver's complete output
receipts, independently validates their checksums, and checks exact UTF-8 bytes.
No replacement implementation or Foundation formatting stub is used.

Qualification passed 40 tests in each of the four baseline/candidate and
debug/release combinations, and compared 4,139 labels. The local timing recovery
inherits those hash-checked test logs and executables and repeats complete output
verification before measuring; it does not claim to rerun compilation or tests.
The recovery and interrupted attempts are described below. Separate
macOS component qualification is tracked in
[the episode display-name workflow](https://github.com/Jagalite/illiquid/actions/workflows/episode-display-name.yml);
its outcome belongs with the retained run evidence, rather than being inferred
from submission.

## Reproduction

Use a Swift toolchain compatible with the package's Swift 6.1 minimum. The
component packages use the toolchain's Swift Testing module and require no
downloaded package dependencies or native playback SDK. Choose a new output
directory for each run; the runner refuses to overwrite an existing one.

When the shared Kyoto queue is available, follow the repository's
[`AGENTS.md`](../../AGENTS.md) and submit the entire runner:

```sh
python3 /Volumes/seed1/Projects/kyoto/kyoto.py submit -- \
  python3 Benchmarks/EpisodeDisplayName/run.py \
  --output /tmp/illiquid-episode-display-study \
  --pairs 12 --target-ms 150 --jobs 2
```

Inspect `show JOB_ID`, `logs JOB_ID`, and `wait JOB_ID` before reporting the
outcome. On a host without Kyoto, the runner explains the limitation before
compiling directly and serially in its own isolated build directories:

```sh
python3 Benchmarks/EpisodeDisplayName/run.py \
  --output /tmp/illiquid-episode-display-study \
  --pairs 12 --target-ms 150 --jobs 2
```

`--swift /path/to/swift` selects a particular toolchain. `--verify-only` runs
source checks, all four test combinations, and full output parity without
timing. Repeated `--case NAME` arguments restrict timed workloads while retaining
the complete qualification step.

The [macOS workflow](../../.github/workflows/episode-display-name.yml) runs the
same component campaign with the pinned Xcode configuration. Its artifact and
chunked compressed log bundle retain the test, source, parity, calibration,
command, and timing receipts. The existing source-tree-sorting workflow provides
separate app-graph/projection checks when the production source changes; a
component pass alone does not establish their outcome.

## Measurement method

[`Driver.swift`](Driver.swift) keeps the production Core module separate from
the benchmark driver, without cross-module optimization. The two workload
families answer different questions:

| Workloads | Timed work | Production interpretation |
| --- | --- | --- |
| `labels-*` | `displayName` for prepared recognized values, output-array construction, checksum consumption, and temporary-object cleanup | Label generation when recognition is already retained in scan entries |
| `recognize-*` | Filename recognition followed by `displayName`, plus the same output consumption and cleanup | The uncached-recognition path and the contribution of formatting within a larger CPU operation |

Numeric episodes, ranges, titled episodes, Unicode titles, and mixed libraries
exercise the changed path. Movie, date, unknown/extra, negative-number, and
wide-integer cases are controls. Positive Int32 values outside ordinary filename
bounds exercise the rest of the supported fast-path domain. The mixed workloads
include unaffected entries, so their reductions cannot be interpreted as the
cost of numeric formatting alone.

Fixtures are constructed before timing. Every sample runs in a fresh process,
performs 16 warm-up evaluations, then measures a fixed amount of work using a
monotonic wall clock and process CPU time. On Darwin, each evaluation includes
an autorelease pool. Initial module/regular-expression setup is outside the
timed region. Every timed output is consumed, and each observation checks its
expected checksum and postflight output against separately verified receipts.

Calibration uses baseline process CPU time to choose one iteration count for
both variants of a workload. An even number of pairs balances baseline-first
and candidate-first order, and case order rotates between pairs. All observations
are retained; the runner does not discard slow or unfavorable samples.

The summary reports per-label and per-batch CPU/wall time. Paired reduction is
`100 * (1 - candidate / baseline)`; negative values indicate increased time.
The paired median and ratio of medians are retained separately. Deterministic
10,000-resample bootstrap intervals describe uncertainty in the paired median;
they are descriptive intervals without a correction across all workloads.

The evidence directory contains the input snapshots and hashes, compiler and
binary identities, complete command logs, test/parity receipts, calibration,
fixed iteration counts, every observation, and the computed summary. Its
`manifest.json` records host/toolchain details, checkout state, selected cases,
and completion status. The baseline snapshot is always checked against its
pinned hashes; when Git history is available, the original production blob is
checked as well and the manifest records that additional verification.

## Local recovery and retained evidence

The completed campaign ran on an AMD EPYC 9V74 shared Linux host on
2026-10-28, from 05:16:44 to 05:17:41 UTC. The compiled source/driver revision
was `84fac120681a7e52db779c2153c6b9b015975e0f`; its inputs are unchanged in this
research result. Compiler identity, host details, and every input hash are in
[`manifest.json`](evidence/linux-x86_64/manifest.json).

The initial campaign passed all four 40-test runs and complete output parity,
then exhausted the shared filesystem while writing a log after 29 observations.
A clean retry stopped when the shared Swift compiler disappeared. Both raw
attempts are retained in [`linux-interrupted`](evidence/linux-interrupted/README.md)
and excluded from the final statistics for those infrastructure failures.

The qualified executables survived and matched their recorded SHA-256 hashes.
A surviving Swift 6.3.2 runtime reproduced all original receipts. Its 14 required
libraries were copied into a private directory and checked against the runtime
inventory; the loader's actual resolution and system-library hashes were also
verified. [`recover.py`](recover.py) verifies the complete provenance chain,
explicitly inherits the four successful test runs, repeats both variants' full
output verification, then calls the frozen runner's **unchanged** calibration
and measurement methods. It uses a new output directory and starts all 12 pairs
from scratch. None of the interrupted timing observations enter these results.

The recovery invocation was:

```sh
python3 Benchmarks/EpisodeDisplayName/recover.py \
  --qualified-run /path/to/qualified-interrupted-run \
  --interrupted-run /path/to/missing-compiler-retry \
  --runtime /path/to/private-verified-runtime \
  --output /path/to/new-recovered-study
```

For normal reproduction, use `run.py` above to compile and qualify everything
on the target host. Recovery requires the original qualified executables and
complete runtime identity receipts; it does not manufacture missing evidence.

The retained result includes:

- [`summary.json`](evidence/linux-x86_64/summary.json): every workload's CPU/wall distributions, paired effects, and intervals.
- [`observations.jsonl.gz`](evidence/linux-x86_64/observations.jsonl.gz): all 360 fresh observations, without filtering.
- [`tests.json`](evidence/linux-x86_64/tests.json) and [`parity.json`](evidence/linux-x86_64/parity.json): 160 inherited successful test executions and fresh exact output qualification for 4,139 labels.
- [`full-run.tar.gz`](evidence/linux-x86_64/full-run.tar.gz): all non-build evidence, including input snapshots, commands, calibration, complete receipts, runtime identities, and both interrupted histories.
- [`independent-audit.json`](evidence/linux-x86_64/independent-audit.json): independently recomputed timing statistics and integrity checks.
- [`archive-manifest.json`](evidence/linux-x86_64/archive-manifest.json): retained-file and archive hashes.

## Qualification limits

Linux results describe the tested Swift/Foundation component on that host.
macOS Foundation, compiler, and hardware can produce different costs; native
measurements must be reported separately. An exact-source component run does
not compile or execute the complete macOS application.

Neither benchmark family includes filesystem discovery, sidecar I/O, full
source-row construction, sorting/grouping, actor scheduling, SwiftUI layout, or
presentation. In particular, `recognize-*` is filename recognition plus label
generation, not an end-to-end library scan. The row cache means this saving is
incurred on relevant rebuilds rather than continuously while the UI is idle.

This campaign does not establish lower whole-player CPU, faster video decoding,
improved frame rate, lower energy use, reduced resident memory, or a particular
change in visible library latency. Those require their own application-level
measurements. Control workloads and any adverse timing observations remain
part of the result.
