# Playlist selection preservation: native performance research

## Result and scope

The final candidate roughly halves the elapsed time of longer current-selection
lookups in the measured native workloads. Every measured middle-hit, late-hit,
and missing-target mutation workload improved in all eight paired trials.
The production diff changes one function:
`PlaylistMutation.indexPreservingCurrentIdentity` (eight added lines and two
removed lines).

The baseline is `main` at
`68274d1b09dcc866296321a5a8858efc297c4f19`. The measured final implementation is
`08bdeba66d2d440ea83bbe324f0e296a65480071`.
[The final native workflow passed](https://github.com/Jagalite/illiquid/actions/runs/39071134091).
These are component lookup timings on warm fixtures; the experiment does not
measure complete playlist commands, playback, UI latency, CPU time, or energy use.

`PlaybackController` calls this helper on its main-actor playlist paths while
sorting, removing, moving, shuffling, restoring, and committing playlist items.
Each call compares changing candidate URLs with one fixed current URL. The
related `FolderPlaylist.index(of:)` stays byte-identical to the baseline and
supplies 13 control workloads. Concurrent [PR #43](https://github.com/Jagalite/illiquid/pull/43)
covers that separate method.

## Why the change helps

Previously, each visited item called
`NormalizedFileURL.representsSameFile(item.url, currentURL)`. For an all-local
scan visiting K items, both URLs were normalized on each comparison: 2K
normalizations, including K repetitions of the invariant target.

For a playlist with at least two items, the candidate prepares a supported target
once, then normalizes each visited item: K + 1 normalizations for the same scan.
An unsupported target skips the scan. An empty array still selects nothing;
a singleton always selects its sole item, regardless of identity or fallback,
so both sizes return their only possible result immediately.

The search stays linear. It adds no persistent cache, index, filesystem access,
or change to the normalization policy. A nonnil target key is required so two
unsupported URLs cannot match through `nil == nil`. First duplicate selection
and fallback bounds stay the same. Items are still normalized when visited:
decoded `FolderPlaylistItem` values can bypass the initializer that usually
prepares their URLs.

There is an input-dependent tradeoff. If a supported target is compared with
only unsupported item URLs, the previous item-first comparison skips target
normalization entirely. The candidate normalizes that target once. A first-item
hit in a longer playlist also has no redundant target work to remove. Both
cases are retained as controls.

## Final measurements

The final native study used eight alternating baseline/candidate pairs for each
of 29 workloads: **464 measured fresh processes plus 53 calibration processes**.
All observations were retained. The tables report median per-call elapsed wall
time. “Reduction” compares those two medians; “paired reduction” is the median
of the eight within-pair percentage reductions. They differ when observations
vary, so both are provided without pooling workloads.

### Multi-item mutation lookups

| Items and scenario | Baseline | Candidate | Reduction | Paired reduction | Faster pairs |
|---|---:|---:|---:|---:|---:|
| 32, middle hit | 129.857 µs | 66.508 µs | 48.8% | 48.6% | 8/8 |
| 32, last hit | 237.883 µs | 122.017 µs | 48.7% | 47.6% | 8/8 |
| 32, missing target | 234.400 µs | 120.415 µs | 48.6% | 48.6% | 8/8 |
| 1,000, last hit | 7.099 ms | 3.677 ms | 48.2% | 48.3% | 8/8 |
| 1,000, missing target | 12.759 ms | 5.334 ms | 58.2% | 56.0% | 8/8 |
| 10,000, last hit | 84.404 ms | 40.567 ms | 51.9% | 54.1% | 8/8 |
| 10,000, missing target | 72.191 ms | 34.825 ms | 51.8% | 50.4% | 8/8 |
| 1,000, long Unicode/path alias | 30.607 ms | 15.391 ms | 49.7% | 49.8% | 8/8 |
| 32, missing target and invalid fallback | 245.080 µs | 124.505 µs | 49.2% | 47.8% | 8/8 |

For example, the 1,000-item last-hit baseline observations ranged from
7.033–7.804 ms, versus 3.632–3.723 ms for the candidate. These ranges describe
the retained observations, not confidence intervals or a guarantee for other
machines.

### Short paths and input controls

| Mutation scenario | Baseline | Candidate | Paired reduction | Faster pairs |
|---|---:|---:|---:|---:|
| Empty | 58.6 ns | 20.9 ns | 62.0% | 8/8 |
| One supported item, first hit | 7.652 µs | 0.021 µs | 99.7% | 8/8 |
| One unsupported item, supported target | 184.7 ns | 20.2 ns | 89.5% | 8/8 |
| One item, unsupported current URL | 3.684 µs | 0.020 µs | 99.5% | 8/8 |
| 32 items, first hit | 7.545 µs | 7.359 µs | 2.1% | 6/8 |
| 1,000 items, nil current URL | 41.1 ns | 38.4 ns | 6.0% | 7/8 |
| 1,000 unsupported items, supported target | 115.903 µs | 121.771 µs | -5.3% | 1/8 |

The singleton cases now avoid identity work altogether. Their approximately
20 ns results include the separately compiled call and checksum loop; they are
not isolated instruction costs. The small first-hit and nil-target differences
do not establish a useful application improvement.

The all-unsupported 1,000-item case regressed by **5.868 µs between medians**
(5.1% longer, or a -5.3% median paired reduction). This is consistent with the
extra eager target normalization, though timing alone cannot attribute every
nanosecond to it. It is retained and disclosed rather than hidden in an average.

All 13 unchanged `FolderPlaylist` controls are included in the
[complete final summary](PerformanceEvidence/PlaylistIdentityLookup/final-macos-summary.json).
Their median paired reductions ranged from -3.0% to +6.6%, despite identical
method source. For the unchanged 10,000-item last-hit control, the ratio of
medians suggested a 10.0% slowdown, while the median paired reduction was +0.4%
with 4/8 faster pairs. This shows why small percentage changes, unpaired medians,
or a single observation should not be treated as implementation effects.
No folder lookup improvement is claimed.

## Correctness qualification

The final workflow passed **22 test functions in four suites** for each of:

| Source variant | Debug | Release |
|---|---|---|
| Frozen baseline | Passed | Passed |
| Final candidate | Passed | Passed |

The isolated packages use the exact four production Foundation source files,
the same four repository test files, Swift tools 6.1, bundled `Testing`, and
the app's macOS 26 deployment boundary. There are no source stubs, rewritten
imports, or external package dependencies. Existing mutation, restoration,
and folder tests run alongside the new identity suite.

The new suite checks dot-segment and Unicode aliases, supported localhost
forms, relative URLs with a local base, raw decoded item URLs, first duplicate
metadata, case/path distinctions, nil and unsupported targets, identical
unsupported URL nonmatches, empty/all-invalid playlists, and fallback bounds
including `Int.min` and `Int.max`.

An independent identity-label oracle enumerates 85 small queues and verifies
3,570 mutation selections, 425 folder lookups, and 510 initial selections:
**4,505 checks**, in addition to direct edge cases. Expected answers do not call
the normalization or lookup helper under test. These cases already cover the
empty/singleton invariant and its target/fallback combinations.

This qualifies the changed component. It is not a full app build, media-decoder
test, or interactive playback qualification.

## Measurement design and reproducibility

The campaign ran on an Apple M1 (Virtual), arm64, with macOS 26.6.2
(build 25G83), Xcode 26.6 (build 17F113), and Apple Swift 6.3.3
(swift-driver 1.148.6). Exact compiler and binary details are preserved in the
final artifact's `manifest.json`.

Each variant's exact production sources are compiled into its own optimized
dynamic `IlliquidCore` module with
`-O -whole-module-optimization -swift-version 6`. An identical driver is
compiled separately against each module. The called public methods are not
`@inlinable`, and no cross-module optimization is enabled. This prevents the
driver from replacing repeated invariant calls with one lookup while retaining
optimization within the production module.

Fixture construction, sorting, target preparation, expected-index derivation,
and one checked warmup occur outside the timed interval. Every timed return
value contributes to a checksum verified after timing. Paired records must
agree on expected index, checksum, workload and iteration count.

Each observation runs in a fresh process. Baseline-first and candidate-first
pairs alternate, with equal counts. Baseline calibration chooses one fixed
iteration count per workload for both variants and all eight retained pairs.
The default target is 40 ms; calibration stops at half that target, eight trials,
or ten million iterations. Final empty/singleton mutation cases start at a
predeclared 500,000-iteration floor, giving the faster candidate loops median
durations around 10 ms. Some matching baseline loops therefore take seconds.
All calibration records remain separately labeled; no observation is rejected
based on its timing.

To reproduce on native macOS with the supported Xcode toolchain:

```sh
python3 Benchmarks/PlaylistIdentityLookup/run.py \
  --mode all --pairs 8 --output /tmp/playlist-identity-evidence
```

The output directory must be new or empty. See the
[runner instructions](../Benchmarks/PlaylistIdentityLookup/README.md) for phase
selection and the full workload matrix. The
[workflow](../.github/workflows/playlist-identity-performance.yml) runs the same
command and retains its artifact. Tests have no performance threshold.

The frozen baseline's file hashes are checked before compilation. An independent
post-run audit verified all 15 source receipts against their recorded commits,
all 464 measured records, 53 calibration records, 533 successful command/log
pairs, balanced execution positions, per-call arithmetic, checked results and
recomputed summaries. This is an evidence-integrity audit of one campaign,
not an additional independent performance replication.

## Initial trial and refinement

[The initial native run](https://github.com/Jagalite/illiquid/actions/runs/39070214459)
tested `6d2e617ffdda47e20ffdb67ab6551619de2c7634`, which changed both lookup
functions. It passed the same four test configurations and measured 29 workloads
in 464 retained and 61 calibration processes.

Its 1,000-item mutation last hit fell from 7.723 ms to 4.054 ms (47.8% median
paired reduction). However, the one-unsupported-item mutation case rose from
0.203 µs to 3.898 µs because eager target preparation added work before the
item-first rejection. That finding motivated the final empty/singleton shortcut.
A concurrent PR covering `FolderPlaylist.index(of:)` also appeared during the
trial, so this PR restores that method to the baseline and keeps its workloads
as controls.

The final study adds the declared short-path iteration floor before collecting
its observations. The two studies have separate implementation and runner
receipts, and their timings are not pooled. The headline results above use only
the final campaign.

## Evidence and limits

[Both original artifact archives, summaries, audits, and run identities](PerformanceEvidence/PlaylistIdentityLookup/README.md)
are preserved with this report. The archives include raw observations, exact
source/test/driver/runner snapshots, compiler/host metadata, command records,
and full command logs. Archive SHA-256 values match the Actions artifact
digests.

The measured effect is well separated from the unchanged controls for longer
supported-file scans. Its size is consistent with eliminating repeated target
normalization. The experiment uses synthetic, warm, unchanged fixtures on one
virtual native host. It does not establish workload frequencies in real use,
cold-cache performance, allocation counts, memory savings, process CPU time,
energy savings, UI responsiveness, or end-to-end playback speed. Complete
playlist commands may also spend time sorting, filtering, restoring order, or
updating playback. Those costs remain outside this experiment.
