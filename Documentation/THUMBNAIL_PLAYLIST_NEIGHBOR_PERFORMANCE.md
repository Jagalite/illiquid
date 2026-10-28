# Background thumbnail playlist neighbor projection

## Finding and scope

Baseline: `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`.

`ThumbnailBackgroundScheduler.runPass` projected every `FolderPlaylistItem.url`
into a new array before looking for the current video. It then kept only the
current item and up to four entries on each side. This made the temporary URL
array proportional to playlist length, including passes with no current video
or with a current URL absent from the playlist.

This work happens synchronously on the main actor before the scheduler submits
thumbnail ranking to a detached task. It is reachable when background thumbnail
generation is enabled and the scheduler admits a pass. Background generation is
opt-in; normal playback without those passes does not receive this improvement.

The finding concerns temporary allocation traffic and neighbor-selection cost.
It is not an unbounded cache or a leaked video frame. The existing playlist,
thumbnail images, decoding buffers, and disk cache are outside this change.

## Change

`ThumbnailPlaylistNeighbors` searches the existing playlist items and copies
only the selected window. It owns an array and a distance dictionary with at
most nine entries each, and it does not retain the playlist or a slice of its
backing storage. A nil current URL returns empty results immediately.

The helper preserves the scheduler's existing rules:

- Match the first item using Foundation `URL` equality. Do not substitute a
  normalized persistence identity or the player's current index.
- Select the same half-open window, from `max(0, anchor - 4)` through
  `min(count, anchor + 5)`.
- Preserve playlist order and repeated URLs in the window.
- Preserve the last occurrence's distance for duplicate URLs in the dictionary,
  including a repeated current URL overwriting distance zero.
- Return empty neighbors and distances when the current URL is absent.

The scheduler still combines current, visible, discovered, neighboring, and
recent URLs in the same order. It uses the same ranking, pass cursor, exclusion
policy, cancellation checks, and generation checks. No asynchronous boundary
was added or removed.

Finding a non-nil current URL still takes up to O(n) comparisons. A match near
the end and a missing match therefore retain linear search cost. The bounded
copy removes the independent O(n) URL projection; it does not make every pass
constant-time.

## Reproduction and method

The runner is
[`Benchmarks/ThumbnailPlaylistNeighbors/run.py`](../Benchmarks/ThumbnailPlaylistNeighbors/run.py).
It stages the complete production helper and actual playlist/core dependencies
into a small component package. The baseline wraps the original scheduler's
projection and distance statements, with a check against the pinned source.
The surrounding SwiftUI application and native media frameworks are not mocked
or compiled in this component package.

```sh
python3 Benchmarks/ThumbnailPlaylistNeighbors/run.py \
  --output /tmp/thumbnail-neighbors-timing --pairs 6 --target-ms 100

# Linux/glibc only; allocation instrumentation is a separate cohort.
python3 Benchmarks/ThumbnailPlaylistNeighbors/run.py \
  --output /tmp/thumbnail-neighbors-allocations \
  --allocations --skip-tests --pairs 2
```

Use fresh output directories. `--swift` selects a compiler explicitly.
`--tests-only` runs the focused correctness gates without a timing campaign.
When the shared Kyoto queue is available, submit these commands through it as
required by `AGENTS.md`; otherwise record its absence and run isolated builds
serially.

Inputs cover empty, 16-, 512-, 10,000-, and 100,000-item playlists, with no
current URL, a missing URL, and first/middle/last positions. The largest input
is a scaling stress case, not an observed user-library size. Fixture creation,
normalization, and warmup are outside the measured operation. Complete neighbor
outputs are checked against a reference outside the timing interval.

Timing uses optimized Swift builds, fresh processes, alternating baseline-first
and candidate-first pairs, and per-operation wall and process CPU measurements.
Each variant is calibrated separately because eliminating an entire scan for
nil/early anchors can produce very different operation costs. Iteration counts
and raw observations are retained. Timing runs do not load the allocation meter.

The separate Linux allocation probe counts successful `malloc`, `calloc`, and
`realloc` requests and their cumulative requested bytes around the operation.
Those values describe allocation traffic, not live heap, peak memory, process
RSS, macOS physical footprint, or GPU allocation. It does not intercept every
possible allocator API. The same probe and fixtures are used for both variants.

## Correctness and integration

The focused suite compares the helper with the old projection across small
playlist boundaries, duplicate anchors, missing and nil inputs, decoded and
noncanonical URL representations, a seeded mixed corpus, and a large playlist.
It checks that returned values remain independent when the original playlist
is replaced or cleared. Existing thumbnail ranking and scheduling-policy tests
run alongside the new tests in debug and optimized configurations.

The
[`thumbnail-playlist-neighbors` workflow](../.github/workflows/thumbnail-playlist-neighbors.yml)
runs the component campaign on Linux and macOS. The repository's existing
restoration/thumbnail workflow builds the actual app graph and runs the native
release suite on pull requests, including `ThumbnailBackgroundSchedulerTests`.
Component measurements alone do not qualify AppKit integration, live playback,
frame pacing, thumbnail throughput, energy use, or end-to-end responsiveness.

## Results

The optimization succeeded at its intended scope: it removes allocation traffic
proportional to playlist length while preserving the neighbor-selection result.
The production helper, scheduler, and Swift tests measured in commit
`e4a31ce145f69f117ece6b7d16799f302d573460` are unchanged by the follow-up
documentation and benchmark-reporting commit.

The [qualification run](https://github.com/Jagalite/illiquid/actions/runs/40634690101)
completed successfully on both Ubuntu 24.04 x86_64 (Swift 6.4) and macOS 26.6.2
arm64 (Apple Swift 6.3.3). The component suite passed 19 tests in each of four
configurations on each platform: baseline debug/release and candidate
debug/release. These are 19 unique tests repeated across configurations, not
76 distinct tests.

Each timing cohort covers 22 cases with six balanced baseline/candidate pairs
and 264 fresh-process observations. The separate Linux allocation cohort has
two balanced pairs, 88 observations, and three operations per observation.
Every measured process checks the expected full output; the runner also checks
parity between variants before timing. Allocation instrumentation must observe
the old 16-item nil-current URL buffer and zero candidate allocations before
the allocation campaign proceeds.

### Allocation traffic

The table reports successful glibc malloc/calloc/realloc **requested bytes per
neighbor selection**, after warmup. It is cumulative allocation traffic, not
memory retained by the player. The request counts include the returned array
and dictionary; fixture construction is excluded.

| Playlist size / current | Baseline bytes/op | Candidate bytes/op | Allocation requests/op |
|---|---:|---:|---:|
| 16/nil | 288 | 0 | 1 → 0 |
| 16/middle | 1,472 | 632 | 6 → 2 |
| 10000/nil | 160,032 | 0 | 1 → 0 |
| 10000/middle | 161,216 | 632 | 6 → 2 |
| 100000/miss | 1,600,032 | 0 | 1 → 0 |
| 100000/middle | 1,601,216 | 632 | 6 → 2 |

For the 10,000-item middle case, requested bytes fall from 161,216 to 632
(**99.61%**). For 100,000 items, they fall from 1,601,216 to 632 (**99.96%**).
The result uses at most nine URLs plus the distance dictionary; first/last
windows request 376 bytes in this Linux cohort. A nil or missing current URL
requests zero candidate bytes after warmup. All repetitions agree in this
cohort, and the earlier local Swift 6.3.2 allocation run produced the same
values.

The removed URL buffer has a 16-byte element stride on the measured Linux
runtime, with an observed 32-byte array overhead. Reserving the bounded
dictionary also avoids its intermediate growth requests. These exact byte
counts are runtime-specific: macOS allocation bytes and whole-process memory
were not measured.

### Native macOS timing

CPU microseconds per neighbor selection are shown below. Baseline and candidate
columns are separate medians of six observations. The percentage column is the
median of the six within-pair percentage changes; it is **not** the ratio of
the two displayed medians. Negative percentages mean less CPU time.

| Playlist size / current | Baseline median µs/op | Candidate median µs/op | Median paired change | Candidate faster pairs |
|---|---:|---:|---:|---:|
| 0/nil | 0.09 | 0.09 | +0.62% | 3/6 |
| 16/middle | 4.74 | 2.33 | -49.40% | 6/6 |
| 512/middle | 44.6 | 22.9 | -51.61% | 6/6 |
| 10000/first | 712.88 | 1.13 | -99.84% | 6/6 |
| 10000/middle | 863.53 | 421.2 | -54.89% | 6/6 |
| 10000/last | 999.5 | 905.38 | -11.63% | 5/6 |
| 100000/first | 7,740.5 | 1.14 | -99.99% | 6/6 |
| 100000/middle | 9,865.9 | 5,077.64 | -48.42% | 6/6 |
| 100000/last | 13,097.61 | 11,306.13 | -6.20% | 4/6 |
| 100000/miss | 13,201.69 | 10,045.33 | -27.35% | 6/6 |

On the native target, the 10,000-item middle case changes from approximately
864 to 421 µs/op. The ratio of those medians is a 51.2% reduction; the median
paired reduction is 54.9%, with all six pairs faster. A first-item match changes
from approximately 713 to 1.13 µs/op because it no longer projects all 10,000
URLs before checking the first item.

Late and missing anchors retain a linear scan. The 100,000-item last-anchor
case improves in only four of six native pairs, and empty controls straddle
zero. The stress sizes demonstrate scaling; they are not measurements of a
known user's playlist or typical workload distribution.

### Linux timing and contrary observations

The hosted Swift 6.4 Linux cohort also improves the nonempty cases, but those
values should not be substituted for native macOS costs. Foundation URL
representations, compiler optimizations, runtime implementations, and hosted
machine conditions can materially change the result.

An earlier local Linux Swift 6.3.2 cohort produced an inconclusive
100,000-item missing-current result: median paired CPU time increased 5.51%,
only three of six pairs were faster, and paired changes ranged approximately
from -28.78% to +54.35%. This counterexample remains part of the assessment even
though the hosted Linux and macOS cohorts improved that case. There is no
claim that every search case is faster on every machine.

## Correctness coverage and reporting detail

The six new helper tests cover:

- Every anchor in playlists of sizes 1 through 24 (300 anchor comparisons).
- Empty, nil-current, and missing-current inputs.
- Duplicate first-anchor selection and last-occurrence distance overwrites.
- Restored URL representations with the same normalized persistence identity
  but distinct Foundation URL equality, as well as non-file URLs.
- A seeded mixed corpus of 2,231 comparisons with the original eager-map oracle.
- A 10,000-item playlist, bounded output, and independence from later input
  replacement or clearing.

The 13 existing thumbnail policy/regression tests bring the component total
to 19. The original runner recorded the last Swift Testing process count in
its manifest. Swift 6.4 emits separate 13-test core and 6-test app summaries,
so that historical manifest reports 6 even though all 19 tests passed.
The follow-up reporting fix sums process counts, records each count, and
requires all three named suites to pass. It changes no production or benchmark
Swift code. Original CI artifact manifests are left intact.

## Retained evidence and provenance

The [evidence index](../Benchmarks/ThumbnailPlaylistNeighbors/evidence/ci-run-40634690101.json)
records the measured commit, baseline commit, run/job identities, artifact
digests, scope, and historical test-count caveat.

Complete numeric summaries are retained in Git:

- [Linux allocation summary](../Benchmarks/ThumbnailPlaylistNeighbors/evidence/linux-ci/allocations-summary.json).
- [Linux timing summary](../Benchmarks/ThumbnailPlaylistNeighbors/evidence/linux-ci/timing-summary.json).
- [macOS timing summary](../Benchmarks/ThumbnailPlaylistNeighbors/evidence/macos-ci/timing-summary.json).

These JSON values were recovered from the qualification workflow's published
summary log groups. Only timestamp prefixes and group markers were removed;
the numeric values were not edited. The summaries include minima, maxima,
medians, every paired percentage change, and the count of faster pairs.

The full original receipts are available in the run artifacts:

- [Ubuntu artifact](https://github.com/Jagalite/illiquid/actions/runs/40634690101/artifacts/12793595213)
  (66,795 bytes; SHA-256
  `fc25c6e3cdbf4e3e086e8f039829b9403b0e586dc3ab1a437fc1c3e26a7cd8a3`).
- [macOS artifact](https://github.com/Jagalite/illiquid/actions/runs/40634690101/artifacts/12793141532)
  (50,557 bytes; SHA-256
  `b52cba43d2c3ec66a9338048d845cddaf65d5e2123aa0462074fb868f21d8650`).

The artifacts contain per-process observations, calibration and iteration
counts, complete verification receipts, source/harness/binary hashes, compiler
and environment information, commands, build/test logs, and completion
receipts. Their configured retention expires on November 11, 2026 (UTC).
The committed summaries remain available after artifact expiration. The local
workspace became unavailable before the larger raw-evidence upload completed;
uncommitted local receipts are therefore not included in this PR. The local
counterexample above is retained as an earlier observed result, while the
hosted summaries and artifacts provide the reviewable measurements.

The frozen baseline scheduler is pinned to commit
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`, Git blob
`61d34cb7e6fc7ed7da2d7bc65dd791d615a5355f`, and SHA-256
`24bee22ce1bc8b670af7e6a45eb49f1a2eac6425c588128af8745ee9ce5f3c9e`.
The runner validates the complete file and extracted projection block before
building. Only the owner-property access is replaced with an input parameter.

## Practical conclusion and limits

The production change removes a proven source of temporary allocation churn
on an admitted background thumbnail pass and provides a repeatable component
speedup for early and middle anchors on the measured native machine. The code
remains small and preserves existing matching and scheduling behavior.

The measurements do not establish reduced whole-player RSS, peak physical
footprint, video-decoder memory, frame pacing, energy use, thumbnail throughput,
or live UI latency. No live AppKit interaction was exercised. The actual
application graph and native scheduler lifecycle suite remain separate PR CI
gates; consult their current checks before merging. There is no new cache,
asynchronous task, global state, or lifetime extension in this change.
