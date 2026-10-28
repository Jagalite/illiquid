# Background thumbnail playlist neighborhood

This study measures the playlist contribution to an **opt-in, idle background
thumbnail pass**. `ThumbnailBackgroundScheduler.runPass` formerly copied every
playlist URL before locating the current item and retaining at most nine
neighbors. `ThumbnailPlaylistNeighborhood.plan` searches the existing items and
copies only that bounded window. A nil current item needs no playlist traversal;
a late or absent current item still needs a linear search.

The change preserves Foundation URL equality, the first matching playlist item,
neighbor order and duplicates, and the final distance assigned to duplicate URL
keys. It does not use the player's selected index, normalize the matching query,
or introduce a cache. The synchronous helper returns only its bounded result.

This is separate from the automatic current-video preparation in `runCurrent`.
Background library generation is disabled by default. These measurements do not
establish smoother playback, faster thumbnail decoding, lower application RSS,
energy savings, or a user-visible latency improvement.

## Reproduce

Use the repository's Kyoto queue for compilation when it is available:

```sh
python3 /Volumes/seed1/Projects/kyoto/kyoto.py submit -- \
  python3 Benchmarks/ThumbnailPlaylistNeighborhood/run.py \
  --output /tmp/thumbnail-neighborhood-study --pairs 12 --target-ms 80
```

On an isolated host without Kyoto, first record that limitation, then run the
same Python command directly. `swift` must be on `PATH`. The output directory
must not already exist. `--tests-only` runs qualification without timing; repeat
`--case NAME` to select measurement workloads from the driver's `--list` output.

## What is measured

There are two measurement boundaries:

1. **Neighborhood:** locate the current URL and build the bounded ordered URL
   array plus distance dictionary.
2. **Candidates:** execute the complete synchronous candidate-preparation prefix
   of `runPass`, including visible/history sorting, URL-list concatenation, and
   the existing `ThumbnailPolicy.Candidate` construction. Ranking, task dispatch,
   duration probes and image generation are outside this boundary.

The baseline is frozen from commit
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`. Its production excerpt and common
source hashes are recorded in `baseline/manifest.json`. The runner checks those
hashes, extracts the candidate prefix from the current scheduler, and compiles
actual production Core sources and the new app helper. Small value containers
stand in for the scheduler's read-only `player.viewStore.playlist` property;
Observation, actor access and the surrounding application are not simulated.

The benchmark executable calls an opaque app-module wrapper. Core, app and
driver are separate Swift modules; cross-module optimization is not enabled.
The app wrapper contains the exact preparation excerpt. The baseline-only
neighborhood wrapper reuses the original excerpt's mapping, search, slicing and
distance statements, excluding the unrelated candidate-list statements.

The 41 workloads include empty/singleton/eight-item controls, 32-, 1,000- and
10,000-item playlists, and a separately identified 50,000-item stress group.
Queries select the first, middle, last, absent or nil current URL. Complete
candidate preparation also covers 256 discovered rows with 24 visible and 16
recent items, and the scheduler's 2,048-row discovery bound with 48 visible and
128 recent items. The prepared item values contain dates and occasional
external-subtitle URLs; fixture construction is outside the timed region.

## Correctness and sampling

Both variants run the new neighborhood regression suite and the existing
thumbnail policy/scheduling suites in debug and release. The new suite includes
700 generated comparisons with the previous algorithm. The driver also emits
397 exact receipts covering neighborhood URLs/distances, the full candidate
records, and ranked results for all three priority settings. Raw decoded URL
spellings, Unicode names, remote URLs, duplicates and absent queries are included.
Visible sets in the raw-URL cases deliberately avoid equal-path sort ties,
because the existing scheduler does not define a tie breaker for those sets.

Each timing observation runs in a fresh process after an untimed warmup. Pairs
alternate baseline/candidate and candidate/baseline order. Each variant is
calibrated independently to the requested process CPU duration and normalized
per call: a nil-current result can be orders of magnitude cheaper than the old
full projection, making equal iteration counts unsuitable for that case. Raw
iteration counts and elapsed times are retained. No empty-loop subtraction is
performed.

Both process CPU time and monotonic wall time include the production call,
result destruction, loop and a small result checksum. On macOS they also include
an autorelease pool per call. Input construction, full output comparisons and
JSON serialization are untimed. The runner checks each observation's checksum,
output count and postflight equality. CPU and wall results are reported
separately, with paired variation retained rather than selecting the best run.

The workflow `thumbnail-playlist-neighborhood.yml` additionally compiles the
native application test graph and runs the focused scheduler regressions on
macOS. A component test pass is not a live UI or media-presentation qualification.

## Results

### Initial Linux study

The first full run used Swift 6.3.2 on a shared Linux x86_64 host, with 12
paired observations per workload (984 timed observations). All 21 focused tests
passed for both implementations in debug and release; all 397 full receipts
matched. [The raw evidence](evidence/linux-main/) retains every observation and
[the complete summary](evidence/linux-main/summary.json). Command stdout/stderr
files named in `commands.jsonl.gz` are preserved in `logs.tar.gz`. Raw command,
calibration and observation JSONL files are compressed without discarding records.

The following rows measure the **complete candidate-preparation prefix**, not
just the neighborhood helper. Times are median process CPU microseconds per
call. Percentage reductions are the median of paired reductions, which need
not equal the reduction calculated from the two separate medians. Intervals
are descriptive paired bootstrap 95% intervals, without a multiple-comparison
adjustment. Positive percentages mean less CPU time.

| Playlist / current / discovered pool | Baseline µs | Candidate µs | Paired CPU reduction | Interval |
|---|---:|---:|---:|---:|
| 1 / first / none | 4.273 | 4.295 | -1.50% | [-7.62%, 4.49%] |
| 8 / middle / none | 22.327 | 19.224 | 17.83% | [-6.84%, 21.64%] |
| 1,000 / first / none | 26.629 | 12.523 | 48.81% | [40.28%, 60.03%] |
| 10,000 / first / none | 144.212 | 12.546 | 91.49% | [87.98%, 92.22%] |
| 10,000 / middle / none | 317.787 | 166.404 | 41.28% | [36.58%, 50.45%] |
| 10,000 / last / none | 364.710 | 310.399 | 18.21% | [10.13%, 21.08%] |
| 10,000 / missing / none | 324.495 | 272.731 | 14.26% | [11.06%, 19.36%] |
| 10,000 / nil / none | 119.746 | 0.128 | 99.89% | [99.88%, 99.90%] |
| 10,000 / first / 256 | 949.174 | 826.587 | 12.15% | [-1.46%, 18.84%] |
| 10,000 / last / 256 | 1204.388 | 1045.825 | 6.27% | [-1.78%, 15.72%] |
| 10,000 / first / 2,048 | 6057.320 | 5960.998 | 2.19% | [-14.79%, 9.49%] |
| 10,000 / last / 2,048 | 6416.740 | 7196.232 | -10.34% | [-38.02%, -0.28%] |
| 10,000 / nil / 2,048 | 6397.607 | 6160.527 | 5.04% | [-11.69%, 14.23%] |

The isolated 10,000-item neighborhood call at the first item fell from 126.266
µs to 0.919 µs (99.26% median paired CPU reduction). Complete preparation has
more work and correspondingly smaller savings. The 50,000-item workloads are
stress cases; they are not a claim about typical playlist sizes.

**Adverse result retained:** the initial 2,048-row pool with the current item at
the end regressed by 10.34% at the paired median. Other full-pool cases had wide
intervals crossing zero. The longer equal-work holdout below addresses this concrete risk without
discarding the adverse result. Native macOS component and application integration
qualification are pending.

### Longer Linux full-pool holdout

The follow-up reused the same verified binaries and source bytes, with **16
pairs and equal work on both sides** (56–67 calls per observation, targeting
about 400 ms). No outliers were removed. The additional baseline-versus-itself
condition measures variation with identical code. All 128 observations passed
the receipt checks. [Full control evidence](evidence/linux-controls/) is retained.

| Condition, 10,000 items / 2,048 discovered | A median CPU ms | B median CPU ms | Paired CPU reduction | 95% interval | B faster |
|---|---:|---:|---:|---:|---:|
| First, baseline / candidate | 6.567 | 6.556 | 0.54% | [−8.09%, 11.66%] | 8/16 |
| Last, baseline / candidate | 6.612 | 7.121 | 1.71% | [−17.53%, 6.05%] | 9/16 |
| Nil, baseline / candidate | 5.958 | 6.819 | −0.007% | [−6.28%, 5.83%] | 8/16 |
| Last, baseline / same baseline | 7.114 | 6.603 | 3.16% | [−4.11%, 11.26%] | 10/16 |

**Full-pool performance remains inconclusive.** The initial directional paired
regression did not reproduce, but this is not a demonstration of equivalence or
non-regression. Marginal medians still show the candidate slower in the last and
nil cases, while the identical-binary control itself differs by 7.18% between its
medians. Keep the measured benefit scoped to large-playlist planning and the
small candidate-pool cases until native results provide stronger evidence.

To rerun these controls after the main runner, preserving its binaries:

```sh
python3 Benchmarks/ThumbnailPlaylistNeighborhood/controls.py \
  --evidence /tmp/thumbnail-neighborhood-study \
  --output /tmp/thumbnail-neighborhood-controls --pairs 16 --target-ms 400
```

The runner verifies measured-source and executable hashes before and after
sampling. It derives output checksums independently from the complete preflight
receipts and uses the original environment. A and B in the same-binary condition
both execute the baseline; they are not alternative implementations.
