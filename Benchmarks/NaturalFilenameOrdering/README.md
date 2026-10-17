# Natural filename ordering research

Date: October 17, 2026. Repository: `Jagalite/illiquid`.

## Decision and production change

Retain a focused optimization in
[`NaturalFilenameOrdering.sort`](../../Sources/IlliquidCore/Utilities/NaturalFilenameOrdering.swift).
The original sort extracts both URLs' `lastPathComponent` during every
comparison. For arrays of three or more URLs, the replacement extracts each
filename once, sorts temporary `(url, name)` entries, and returns the original
URL values in the resulting order. Filename extraction becomes one operation
per input entry; the sorting algorithm still performs its comparisons.

Empty and singleton inputs return immediately. Two-element inputs use the
original comparator because their single comparison already extracts each name
once. An exploratory version also constructed temporary entries for two URLs;
that extra work regressed the tiny case and motivated this explicit guard. The
table below comes entirely from the final guarded implementation.

The public `areInIncreasingOrder` function is unchanged. Both paths retain
`localizedStandardCompare`, followed by the original literal full-path comparison
when filenames compare equally. Full paths are still extracted only for ties.
Comparator-equal URLs retain their input order. The code returns the original
URLs, preserving their relative bases, authority, encoding, query and fragment;
it does not reconstruct URLs from the retained names or normalize them.

The temporary entries and retained filename keys add O(n) array/key storage,
plus the bytes of the retained names. The entry array can coexist with the
returned URL array while that result is constructed. This tradeoff was not
measured with an allocation or footprint instrument, so no memory saving is
claimed. There is no persistent filename cache or new filesystem lookup.

## Source provenance and compilation boundary

The retained baseline is
[`baseline/NaturalFilenameOrdering.swift`](baseline/NaturalFilenameOrdering.swift),
identified by [`baseline/manifest.json`](baseline/manifest.json):

| Field | Value |
| --- | --- |
| Repository commit | `68274d1b09dcc866296321a5a8858efc297c4f19` |
| Production path | `Sources/IlliquidCore/Utilities/NaturalFilenameOrdering.swift` |
| Git blob | `3e31506bdec552337ce25dfeaf54da2afc6e6c1d` |
| SHA-256 | `392fdfb0ea35cd2a30804a3f07f23c489130f026e22ba32dd2b9f40216c60a4c` |

The final measured candidate's SHA-256 is
`cbf5e576464acd43803aefc0f65013fd218a6efadd8adaa6940eeea3e2151fee`.
The evidence also records hashes for every supporting source, driver, Python
runner, and compiled executable. The six supporting production files are copied
unchanged into both variants: `NormalizedFileURL`, `MediaFileSupport`,
`FolderPlaylist`, `PlaylistMutation`, `ExternalSubtitleMatcher`, and
`FolderPlaylistDiscovery`. Only `NaturalFilenameOrdering.swift` differs.

Each variant compiles these actual source files and the driver together with
`swiftc -O -whole-module-optimization -swift-version 6 -warnings-as-errors`.
Production source snapshots compile without platform shims.
This is a **same-module, whole-module-optimized component experiment**. It does
not reproduce the application's module boundary, SwiftPM dependency graph,
SwiftUI rendering, or native playback execution.

## Reproduce

Requirements: Python 3.10 or later, Swift 6.1 or later with its bundled Testing
library, and the complete repository checkout. The retained Linux cohort used
Swift 6.3.2. Select the corresponding `swift` on `PATH` for tests; `--swiftc`
can select an explicit compiler for the benchmark. No dependency download or
complete app build is needed by these focused commands.

```sh
# New ordering regressions and the existing core utility tests.
bash Scripts/test-natural-filename-ordering.sh --jobs 2 -Xswiftc -warnings-as-errors
bash Scripts/test-natural-filename-ordering.sh -c release --jobs 2 -Xswiftc -warnings-as-errors

# Existing folder-discovery integration and filesystem regressions.
bash Scripts/test-folder-discovery-regressions.sh --jobs 2 -Xswiftc -warnings-as-errors
bash Scripts/test-folder-discovery-regressions.sh -c release --jobs 2 -Xswiftc -warnings-as-errors

# Complete 18-case comparison; every output directory must be new or empty.
python3 Benchmarks/NaturalFilenameOrdering/run.py \
  --pairs 10 --target-ms 100 --output /tmp/illiquid-natural-filename-ordering
```

The retained Linux run prefixed the benchmark command with `taskset -c 8`,
pinning its processes to CPU 8. Use an available CPU on another Linux host;
macOS does not require this Linux command. Run timing separately from builds,
tests and other benchmarks. A short smoke comparison can select exact case IDs:

```sh
python3 Benchmarks/NaturalFilenameOrdering/run.py \
  --pairs 2 --target-ms 30 --case sort-shuffled-8 \
  --case playlist-128-no-subtitles --output /tmp/illiquid-natural-filename-smoke
```

Smoke results check the harness and output parity; use a complete repeated cohort
to assess performance. `--list-cases --output /tmp/illiquid-natural-filename-cases`
compiles the two variants and prints the workload manifest without timing.

## Correctness coverage

The focused suite contains seven new sorting tests and four existing
`UtilitiesTests`. It covers empty/singleton inputs, numeric ordering before
directory ordering, literal path ties, stable comparator-equal URLs, exact
duplicates, idempotence, input preservation, case/diacritics/numeric variants,
directory URLs, percent-encoded paths, and relative URLs with file and remote
bases. URL comparisons retain absolute and relative representations and base
information, so an implementation that reconstructs superficially equivalent
URLs cannot silently pass. A deterministic corpus compares 120 lists of up to
257 URLs against `input.sorted(by: NaturalFilenameOrdering.areInIncreasingOrder)`.
Locale-sensitive expectations use the unchanged public comparator instead of
requiring one locale's accent or case order.

The separate folder-discovery runner covers the existing model and actual
temporary-filesystem behavior. These correctness tests are independent of timing
thresholds. The macOS test status is described below.

All three Linux runs passed against the final candidate hash recorded above:

| Validation | Result | Retained log |
| --- | --- | --- |
| Focused ordering/utilities, debug | 11 tests passed | [tests-debug.txt](evidence/linux/tests-debug.txt) |
| Focused ordering/utilities, release | 11 tests passed | [tests-release.txt](evidence/linux/tests-release.txt) |
| Existing folder-discovery integration | 19 tests passed | [tests-folder-discovery.txt](evidence/linux/tests-folder-discovery.txt) |

Before timing, the benchmark compares complete baseline/candidate outputs for
all 18 cases. It then checks the complete final output of every calibration and
measurement process, plus the timed consumer's checksum. For playlists, the
complete comparison includes ordered URLs, subtitle associations, metadata
dates, and the folder URL. All **360 measured processes and 36 excluded
calibration processes passed output parity**. Full receipts are compared in
memory; retained evidence stores their SHA-256 digests to avoid committing
thousands of repeated URL records.

## Workloads and measurement protocol

The retained run used Swift 6.3.2 on x86_64 Linux, glibc 2.39, locale `en_001`,
with CPU affinity restricted to logical CPU 8. Each process constructs synthetic
fixtures and warms its operation once before the measured loop. Inputs are
reused within the process. This measures **warm in-memory work**.

The sort cases cover empty, singleton and two-item controls; shuffled, sorted
and reversed numeric filenames; varied Unicode names; and filename ties across
different folders. The playlist cases call the actual
`FolderPlaylistDiscovery.makePlaylist`, including lexical URL normalization,
sorting, subtitle association, item creation, supplied dates and deduplication.
The subtitle case supplies 1,000 media URLs and 1,000 matching subtitle URLs.
The other playlist cases supply no subtitles. Fixture creation, filesystem
enumeration, metadata reads from disk and visible application behavior are
outside this integration measurement.

Each of the 18 cases has **10 fresh-process pairs**, alternating baseline then
candidate (AB) and candidate then baseline (BA): five pairs in each order. The
runner first calibrates each variant toward a 100 ms batch, then fixes both
variants to the larger chosen iteration count for all measured pairs in that
case. This is a calibration target, not an enforced duration. Some large cases
already exceed it with one iteration. Every measurement process performs its own
untimed warmup before the fixed-count batch.

The timer includes the actual operation, a small result consumer, loop overhead,
and intermediate-result lifetime management. The consumer observes collection
size and the first/last URLs without hashing the entire collection on each
iteration. Full-output receipt construction, serialization and equality checks
run after timing. One operation means one complete sort or one complete playlist
construction. Timings are elapsed wall time per operation; they are not process
CPU, UI latency percentiles, cold folder-open time, energy, or memory measurements.

## Final Linux results

The table reports the median of ten per-process means for each variant, in
milliseconds. Reduction is `100 × (1 − candidate median / baseline median)`.
“Faster pairs” counts how often the candidate's process mean was lower in its
matched pair. Raw per-pair reductions, minima and maxima remain in
[`evidence/linux/summary.json`](evidence/linux/summary.json).

| Case | Before (ms) | After (ms) | Median reduction | Faster pairs |
| --- | ---: | ---: | ---: | ---: |
| `sort-empty` | 0.00003119 | 0.00001268 | 59.3% | 10/10 |
| `sort-singleton` | 0.0001830 | 0.0001100 | 39.9% | 10/10 |
| `sort-shuffled-2` | 0.004788 | 0.004629 | 3.3% | 9/10 |
| `sort-shuffled-8` | 0.107540 | 0.066817 | 37.9% | 10/10 |
| `sort-shuffled-24` | 0.378820 | 0.222535 | 41.3% | 10/10 |
| `sort-sorted-8` | 0.017286 | 0.013202 | 23.6% | 9/10 |
| `sort-reversed-24` | 0.708044 | 0.388795 | 45.1% | 10/10 |
| `sort-shuffled-128` | 3.171922 | 1.745769 | 45.0% | 10/10 |
| `sort-shuffled-1000` | 48.554862 | 25.748721 | 47.0% | 10/10 |
| `sort-shuffled-10000` | 454.854918 | 247.505553 | 45.6% | 10/10 |
| `sort-sorted-10000` | 23.949308 | 18.407298 | 23.1% | 9/10 |
| `sort-reversed-10000` | 24.806159 | 17.621278 | 29.0% | 9/10 |
| `sort-unicode-1000` | 85.848063 | 58.092420 | 32.3% | 10/10 |
| `sort-ties-1000` | 83.371091 | 66.511691 | 20.2% | 10/10 |
| `playlist-128-no-subtitles` | 7.292381 | 6.184536 | 15.2% | 9/10 |
| `playlist-1000-no-subtitles` | 81.489925 | 59.520562 | 27.0% | 10/10 |
| `playlist-10000-no-subtitles` | 1273.545238 | 700.116810 | 45.0% | 10/10 |
| `playlist-1000-with-subtitles` | 184.689168 | 147.134653 | 20.3% | 10/10 |

The strongest consistent sort cases support a useful reduction in repeated
filename extraction: shuffled 1,000- and 10,000-item inputs improve about 47%
and 46% by the table's statistic. The 1,000-item playlist integration improves
27% without subtitles and 20% with them. Those figures describe these specific
in-memory operations on this host.

The controls require different interpretations. Empty/singleton percentages
represent tens of nanoseconds in this loop, where consumer and loop overhead
matter; they are not useful app-level headline gains. The two-item case retains
the original comparison path, so its 3.3% median difference is a non-regression
control rather than evidence that filename caching accelerates two URLs.

Host variability remains visible despite CPU affinity. In particular,
`playlist-10000-no-subtitles` spans **762.5–1,506.1 ms** for the baseline and
**586.8–1,146.7 ms** for the candidate. Although all ten candidate pairs are
faster, paired reductions range from **1.3% to 59.0%**, with a paired median of
**38.0%**, compared with the table's **45.0%** ratio-of-medians reduction. This
supports a direction of improvement but leaves its magnitude imprecise. The
Unicode case also has different paired-median and ratio-of-medians reductions.
These statistics are intentionally kept distinct.

Some sorted/reversed controls and the 128-item playlist lose one pair; all such
observations remain in the evidence. Ten faster pairs do not establish a
confidence interval, and the 18 cases should not be averaged into one player
speedup. Affinity controls CPU placement without controlling contention,
frequency, throttling or thermal conditions. Linux Foundation and the selected
same-module build also differ from the native macOS application.

## Evidence and native qualification

[`evidence/linux`](evidence/linux) retains the completed environment record,
case manifest, source/build hashes, command log, initial verification digests,
all measured and calibration rows, and the full summary. Calibration rows are
marked `phase: "warmup"` and excluded from reported medians. No completed timing
observations were filtered. Build products are reproducible and are not required
in the retained evidence.

The dedicated
[`natural-filename-ordering.yml`](../../.github/workflows/natural-filename-ordering.yml)
workflow runs focused debug/release tests and this benchmark on macOS 26 with
Xcode 26.6, then uploads the `natural-filename-ordering-macos` artifact. Its
default benchmark calibration target is 50 ms; the published Linux cohort
explicitly requested 100 ms. The existing restoration workflow also runs the
complete native release test suite and builds the app dependency graph for
every pull request.

**macOS results are pending.** Inspect the PR checks and native evidence before
merging. This report claims completed portable component research; it does not
claim measured macOS responsiveness, end-to-end player performance, or native
application qualification.
