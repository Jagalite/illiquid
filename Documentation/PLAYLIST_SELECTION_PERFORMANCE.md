# Playlist selection performance research

## Result and scope

Caching the current URL's canonical identity within one
`PlaylistMutation.indexPreservingCurrentIdentity` invocation reduced component
selection time by **45.0–51.1%** for the measured middle, last, and missing
selection cases at 100, 1,000, and 10,000 items. These are the medians of eight
paired time reductions for each case. The publication cohort ran on Linux;
macOS timing and Foundation qualification are pending the accompanying workflow.
No whole-application, playback, or frame-rate improvement is claimed.

The production change is confined to
[`PlaylistMutation.swift`](../Sources/IlliquidCore/Playlist/PlaylistMutation.swift).
The baseline is main commit
[`68274d1b09dcc866296321a5a8858efc297c4f19`](https://github.com/Jagalite/illiquid/commit/68274d1b09dcc866296321a5a8858efc297c4f19).
Source fingerprints identify the exact measured candidate in the
[evidence manifest](../Benchmarks/PlaylistSelection/evidence/linux-x86_64/manifest.json).
The baseline and candidate use identical `NormalizedFileURL`, `FolderPlaylist`,
and `NaturalFilenameOrdering` implementations.

## Why this area

The main-actor playback coordinator in
[`PlaybackController.swift`](../Sources/IlliquidPlayer/Player/PlaybackController.swift)
calls this helper to retain the playing resource after playlist sorting,
shuffle changes, moves, removals, restored sessions, and opening queues.
A deep linear search repeatedly normalizes the same current URL. The existing
predicate evaluates one item key and one current key per eligible item.

For a successful or missing all-local search visiting `s` items, the change
reduces key evaluations from `2s` to `s + 1`. The current key is computed lazily
after the first eligible item, then retained only until the call returns.
A first-item match still evaluates two keys. Empty lists, a nil current URL,
and lists containing only unsupported URLs do not compute a current key.
An unsupported current URL can stop the search once its rejection is known.

This preserves first-match behavior, duplicate handling, fallback precedence,
and the existing URL identity policy. Each visited item still goes through
`NormalizedFileURL.persistenceKey`, including items decoded with noncanonical
URLs. The code does not depend on an item's fallback `id`, which can contain an
unsupported raw URL. The cache has constant space and no lifetime beyond the
call. Other work done by the coordinator, including sorting and additional
identity searches, is outside this measurement.

An exploratory attempt to simplify persistence-key construction itself showed
mixed results across filename sets and was discarded. The submitted change
removes repeated work at the call site while using the existing canonicalizer.

## Publication measurements

The completed cohort ran on 2026-10-17, approximately 21:15–21:17 UTC, using
Swift 6.3.2, Python 3.12.14, and Linux x86_64 with glibc 2.39. The shared host
reported an Intel Xeon Platinum 8573C and nine logical CPUs. CPU affinity and
clock frequency were not controlled. Host details are in
[`host.json`](../Benchmarks/PlaylistSelection/evidence/linux-x86_64/host.json).

The table shows median milliseconds per selection and median paired speedup
and time reduction. A median of paired ratios is not necessarily the ratio of
the separately reported medians.

| Search | Items | Baseline ms | Candidate ms | Paired speedup | Paired time reduction |
| --- | ---: | ---: | ---: | ---: | ---: |
| Middle match, ASCII | 100 | 0.610 | 0.312 | 1.97× | 49.2% |
| Middle match, ASCII | 1,000 | 6.325 | 3.037 | 2.05× | 51.1% |
| Middle match, ASCII | 10,000 | 61.043 | 30.303 | 2.02× | 50.4% |
| Last match, ASCII | 100 | 1.203 | 0.611 | 1.99× | 49.6% |
| Last match, ASCII | 1,000 | 11.853 | 6.066 | 1.97× | 49.2% |
| Last match, ASCII | 10,000 | 121.248 | 61.067 | 2.00× | 49.9% |
| Missing, ASCII | 100 | 1.161 | 0.596 | 1.98× | 49.4% |
| Missing, ASCII | 1,000 | 11.868 | 5.980 | 1.99× | 49.6% |
| Missing, ASCII | 10,000 | 117.042 | 61.244 | 1.95× | 48.7% |
| Last match, Unicode | 100 | 1.470 | 0.735 | 1.99× | 49.9% |
| Last match, Unicode | 1,000 | 14.385 | 7.217 | 1.99× | 49.8% |
| Last match, Unicode | 10,000 | 150.314 | 74.738 | 2.01× | 50.3% |
| Missing ASCII query, Unicode items | 100 | 1.303 | 0.707 | 1.85× | 45.8% |
| Missing ASCII query, Unicode items | 1,000 | 13.435 | 7.311 | 1.82× | 45.0% |
| Missing ASCII query, Unicode items | 10,000 | 133.610 | 72.315 | 1.85× | 46.0% |

First-item controls showed small paired slowdowns of 0.7–2.2%, at roughly
12 microseconds per call. Single-item local searches showed paired changes
between a 2.0% slowdown and a 1.2% improvement. All-unsupported-item controls
ranged from a 2.3% slowdown to a 0.6% improvement. These small changes, alongside
visible process outliers, do not support a claim of improved cheap-path timing.
Nil-current and empty controls are only a few nanoseconds per call; their
percentage changes should not be interpreted as meaningful application gains.
All cases, including unfavorable observations, are retained below and in the
[raw measurements](../Benchmarks/PlaylistSelection/evidence/linux-x86_64/measurements.jsonl).

The unsupported-current case benefits from early exit, but the iteration
budget leaves only one candidate call in the 10,000-item measurement. Its
roughly seven-microsecond timer interval makes a precise multiplier unhelpful;
it is excluded from the headline speedup. `missing-unicode` means a missing
ASCII current URL searched among Unicode-named items, not a Unicode query.

The candidate still performs a linear search: its 10,000-item ASCII last-match
median was 61.067 ms on this host. The reduction does not establish that a large
playlist mutation fits a UI frame budget or avoids visible stalls.

## Method and validation

The runner compiles the four exact production files into an optimized shared
library for each variant. The benchmark driver is compiled separately and calls
the public, non-inlinable helper without cross-module optimization. This keeps
the measured helper call observable to the optimizer. Every result contributes
to a checksum checked against a known selection. Fixtures, URL construction,
expected results, and three warmup calls are outside the timer. The measured
interval includes selection calls and checksum accumulation, and excludes
process launch time.

There are 37 workload/size combinations, eight fresh-process pairs per case,
and 592 timed process observations. Pair order alternates baseline/candidate
and candidate/baseline. Both variants use the same predeclared iteration count,
based on a budget of approximately 10,000 visited items. Exact counts and
orders are recorded in the manifest and observations. Builds, tests, and
measurements run sequentially. This is one shared-host cohort, with descriptive
medians and ranges rather than a statistical confidence claim. Timing has no
pass/fail threshold in CI.

Correctness gates passed before timings were accepted:

- **7,296 deterministic selections** produced byte-identical baseline and
  candidate receipts, with zero mismatches against the original predicate.
  The 7,297th JSONL line is the verification summary. The corpus covers Unicode,
  dot components, escaped paths, local/remote authorities, decoded items,
  duplicate identities, reorderings, seeded mixed arrays, and fallback limits.
- **22 tests in four suites passed in each of four configurations:** baseline
  debug, baseline release, candidate debug, and candidate release. These include
  existing playlist mutation, folder playlist, and order restoration suites,
  plus the new independent expected-result tests in
  [`PlaylistSelectionIdentityTests.swift`](../Tests/IlliquidCoreTests/PlaylistSelectionIdentityTests.swift).
- Every timing pair matched iteration counts, operation counts, and selection
  checksums. All **604 recorded commands exited successfully**. Source snapshots,
  command receipts, raw observations, and summaries were verified after writing.
- A separate read-only review recomputed all summary statistics from the raw
  rows, checked all 1,208 command-output receipts and the parity files, and found
  no correctness or evidence inconsistencies.

## Reproduction and retained evidence

```sh
python3 Benchmarks/PlaylistSelection/run.py --output /tmp/playlist-selection
```

Use a new output directory, Swift 6.1 or newer with Swift Testing, and Python
3.10 or newer. See the [harness README](../Benchmarks/PlaylistSelection/README.md)
for toolchain options and test-only runs. Frozen baseline files are checked
against their original Git blob IDs and SHA-256 hashes before each run.

The [publication evidence directory](../Benchmarks/PlaylistSelection/evidence/linux-x86_64)
contains all raw measurements, summaries, exact commands, test-command IDs,
toolchain/source/binary fingerprints, full parity receipts, and completion
status. `command-receipts.jsonl.gz` losslessly combines the 1,208 individual
stdout/stderr files: each record has the original relative `path` and its UTF-8
`text`. Re-encoding that text reproduces the bytes checked by the hashes and
lengths in `commands.jsonl`. `sources.tar.gz` retains all 16 measured source,
runner, harness, manifest, and test files. `packaging.json` maps snapshots to
repository paths and records the packaged files' sizes and hashes. Generated
packages, build products, and compiler binaries are reproducible and omitted.

The new [macOS workflow](../.github/workflows/playlist-selection-performance.yml)
runs the same tests, parity checks, and timing schedule on `macos-26`, and uploads
complete run evidence. Native results should be evaluated using that run's
recorded toolchain, actual corpus count, and measurements. A passing component
workflow does not constitute a full application build or physical-device
playback test; neither was run in this Linux environment.

## Complete case medians

Values are microseconds per selection. Positive paired change means less time;
negative means more time. The machine-readable summary also retains each
variant's minimum and maximum and the ratio of medians. Extra decimals below
preserve cheap controls without implying timing precision.

| Workload | Items | Baseline µs | Candidate µs | Paired time reduction |
| --- | ---: | ---: | ---: | ---: |
| `head` | 1 | 12.0467 | 12.0588 | -1.97% |
| `head` | 100 | 11.7214 | 11.9608 | -2.12% |
| `head` | 1,000 | 11.7438 | 11.7860 | -0.74% |
| `head` | 10,000 | 11.7312 | 11.9006 | -2.24% |
| `middle` | 1 | 12.2818 | 12.5889 | +1.00% |
| `middle` | 100 | 610.3282 | 312.0637 | +49.20% |
| `middle` | 1,000 | 6325.3422 | 3036.8002 | +51.15% |
| `middle` | 10,000 | 61043.3090 | 30302.5250 | +50.44% |
| `tail` | 1 | 11.8827 | 11.8890 | +1.23% |
| `tail` | 100 | 1202.6053 | 610.9592 | +49.63% |
| `tail` | 1,000 | 11852.8926 | 6066.0397 | +49.23% |
| `tail` | 10,000 | 121247.9680 | 61066.9535 | +49.90% |
| `missing` | 1 | 11.5198 | 11.7138 | -1.63% |
| `missing` | 100 | 1161.3932 | 596.0670 | +49.39% |
| `missing` | 1,000 | 11867.8219 | 5980.0086 | +49.64% |
| `missing` | 10,000 | 117042.4155 | 61243.6765 | +48.69% |
| `invalid-current` | 1 | 6.6644 | 6.6048 | -0.41% |
| `invalid-current` | 100 | 660.2242 | 6.5556 | +99.03% |
| `invalid-current` | 1,000 | 6654.3812 | 6.3563 | +99.90% |
| `invalid-current` | 10,000 | 68761.9510 | 7.1230 | +99.99% |
| `nil-current` | 1 | 0.0034 | 0.0034 | +0.07% |
| `nil-current` | 100 | 0.0035 | 0.0035 | +2.83% |
| `nil-current` | 1,000 | 0.0035 | 0.0035 | -0.26% |
| `nil-current` | 10,000 | 0.0034 | 0.0036 | -1.57% |
| `tail-unicode` | 1 | 14.6829 | 14.5410 | +0.91% |
| `tail-unicode` | 100 | 1469.6493 | 734.5121 | +49.87% |
| `tail-unicode` | 1,000 | 14385.3197 | 7217.0110 | +49.82% |
| `tail-unicode` | 10,000 | 150313.8215 | 74738.3460 | +50.25% |
| `missing-unicode` | 1 | 12.9537 | 13.0551 | -1.39% |
| `missing-unicode` | 100 | 1303.3793 | 707.3635 | +45.84% |
| `missing-unicode` | 1,000 | 13435.4274 | 7311.2328 | +44.98% |
| `missing-unicode` | 10,000 | 133609.7510 | 72315.0140 | +46.00% |
| `all-invalid-items` | 1 | 0.1024 | 0.1014 | -1.04% |
| `all-invalid-items` | 100 | 8.4540 | 8.3797 | -1.36% |
| `all-invalid-items` | 1,000 | 83.8180 | 86.3006 | -2.32% |
| `all-invalid-items` | 10,000 | 861.1195 | 847.2740 | +0.60% |
| `empty` | 0 | 0.0031 | 0.0026 | +9.60% |
