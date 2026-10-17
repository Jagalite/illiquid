# Playlist identity lookup qualification

The production change covers `PlaylistMutation.indexPreservingCurrentIdentity`.
For playlists with at least two items, it computes the target URL's canonical
path once per lookup, instead of once for every valid item visited. Each visited
item's identity is still computed normally, and the search remains linear.
Empty and singleton playlists return their only possible result directly:
`nil` for empty input and index `0` for one item. Neither identity matching nor
fallback selection can produce a different answer for those sizes. No
persistent identity cache or filesystem lookup is introduced.

The final candidate leaves `FolderPlaylist.index(of:)` unchanged. Its 13
workloads remain in the experiment as unchanged-code controls. The initial
two-function study is retained separately from the final mutation-only study;
its source snapshots and runner hashes identify the earlier candidate and
calibration policy. Do not combine observations from the two studies.

The frozen baseline is `Jagalite/illiquid` commit
`68274d1b09dcc866296321a5a8858efc297c4f19`. `baseline/manifest.json` records the
original repository paths and SHA-256 hashes for all four unmodified production
source files. The runner verifies these hashes before compiling either variant.

## Run the qualification

On the repository's native macOS/Xcode runner:

```sh
python3 Benchmarks/PlaylistIdentityLookup/run.py \
  --mode all --pairs 8 --output /tmp/playlist-identity-evidence
```

The output directory must be new or empty, and the pair count must be even.
Individual phases and a shorter
two-pair smoke run are available:

```sh
python3 Benchmarks/PlaylistIdentityLookup/run.py \
  --mode tests --output /tmp/playlist-identity-tests
python3 Benchmarks/PlaylistIdentityLookup/run.py \
  --mode benchmark --pairs 2 --output /tmp/playlist-identity-smoke
```

The two-pair run checks the experiment's mechanics; use repeated native
measurements to assess performance. There is no timing-based pass/fail threshold.

## Correctness and compilation

The test phase creates four independent temporary Swift packages: baseline and
candidate, each in debug and release. Each package contains the exact four
production source files and the same repository test files:

- `PlaylistIdentityLookupTests.swift`
- `PlaylistMutationTests.swift`
- `PlaylistOrderRestorationTests.swift`
- `FolderPlaylistTests.swift`

The packages use Swift tools version 6.1, the toolchain's bundled `Testing`
module, and the app's macOS 26 deployment boundary. They have no external package
dependencies and do not build the macOS playback adapters. These are component
tests, not a full app build or playback qualification.

For timing, each variant's exact production files are compiled together into a
separate dynamic `IlliquidCore` module with
`-O -whole-module-optimization -swift-version 6`. The identical driver is then
compiled separately against that module. No cross-module optimization is
enabled, and the called public lookup methods are not `@inlinable`. This preserves
optimization between production source files while preventing the driver from
folding repeated invariant lookups into one call.

## Workloads and timing method

There are 29 workloads: 16 mutation cases and 13 unchanged folder controls.
Each API receives the following 13 cases:

| Item count | Scenarios |
|---:|---|
| 0 | Empty playlist |
| 1 | First match; all unsupported item URLs with a valid local target |
| 32 | First, middle, last, and missing target |
| 1,000 | Last match; missing target; long Unicode/path alias; all unsupported item URLs |
| 10,000 | Last match; missing target |

Three additional mutation cases exercise a nil current URL, an unsupported
current URL with a valid fallback, and a missing current URL with an invalid
fallback. Ordinary match cases use canonical prepared current URLs. The long
alias case separately uses a decomposed Unicode target with a dot segment and
a long path. Unsupported item URLs use `example.invalid`; no request or other
network operation occurs.

All items, metadata, sorting, target URLs, and expected indices are prepared
before timing. The folder fixture deliberately starts reversed, then checks the
constructor's actual sorted order against independent integer labels stored in
date metadata. Expected lookup results come from those labels and explicit
fallback rules, not the production identity helpers. Each process checks one
untimed warmup against the expected answer. The timed loop consumes every
returned index into a checksum, which is checked after the clock stops.
Baseline/candidate pairs must also agree on their expected index, checksum,
workload, and iteration count.

The runner retains every baseline calibration trial. The final study defines
a **500,000-iteration minimum for mutation workloads with at most one item**,
applied as the initial calibration count. All other workloads start with one
call. This floor allows the final candidate's fast empty/singleton path to
produce a measurable loop duration; it intentionally makes some corresponding
baseline loops take seconds rather than approximately 40 ms. The floor was
chosen before collecting the final study's measurements and is recorded in its
manifest. The initial two-function study used one call as every initial count.

From that initial count, calibration only increases iterations toward
`--target-ms` (default 40 ms), stopping once a trial reaches half that target,
eight trials have run, or ten million iterations are reached. The resulting
**same fixed iteration count** is used for both variants and every retained pair
for that workload. Calibration records are identified separately and excluded
from the reported measurement summary by design; no observations are rejected
based on their timing.

Each retained observation runs in a fresh process. Baseline-first and
candidate-first pairs alternate. At the default eight pairs, every workload has
eight baseline and eight candidate observations. The summary reports the median
elapsed time per call, the reduction between variant medians, the median paired
reduction, ranges, the number of pairs where the candidate is faster, and the
median measured loop duration. Very short controls should be interpreted using
those loop durations and their absolute time changes, not percentage alone.
These are repeated lookups on warm, unchanged in-memory fixtures; cold-cache
behavior is not measured.

The all-unsupported-item mutation cases expose an input-dependent tradeoff for
larger lists: the old helper short-circuits before normalizing the target when
each item is unsupported, whereas eager target preparation performs that work
once. The final candidate's singleton fast path avoids both item and target
normalization. The initial trial lacked that fast path, and its singleton
unsupported-item result is retained with that trial. Report all controls
alongside successful valid-file cases rather than hiding them in an average.

## Evidence and interpretation

The output includes:

- `manifest.json`: compiler, host, commit/status, flags, source/binary hashes, and baseline provenance.
- `sources/`: exact baseline, candidate, test, harness, runner, and manifest snapshots.
- `commands.jsonl` and `logs/`: exact commands, exit statuses, execution times, and complete process output.
- `workloads.json` and `observations.jsonl`: workload definitions and every calibration/measurement observation.
- `summary.json`: incrementally saved test results and per-workload timing summaries.

Failure preserves completed evidence and marks the summary as failed. Successful
workload summaries also appear in CI logs as `BENCHMARK_SUMMARY` JSON records;
`QUALIFICATION_PASS` records completion. Build products live separately under
`build/` and need not be included in the evidence artifact.

These measurements describe **function-level elapsed wall time** on the recorded
host. They do not establish UI latency, frame rate, decoder throughput, energy
use, process CPU time, or end-to-end playback improvement. The local research
environment did not have a usable Swift toolchain; native results must come
from the linked Actions run and its retained evidence.
