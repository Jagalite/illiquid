# Video tab admission performance

Date: October 17, 2026. Baseline: `8c3cc3d4008d5d1b8d436bcf2d51d891382b6548`.

## Decision

Keep a resource-to-tab-ID index in `OpenVideoTabs`, and append only the newly
admitted visible item in `OpenVideoTabStore`. The actual-source release benchmark
shows a substantial reduction in the work performed by the player's synchronous
tab-admission loop. The tradeoffs are a small first-tab cost and an additional
derived resource index in memory.

The production change is limited to these two files. It does not change resource
normalization, filesystem identity resolution, playlist ordering, saved state,
or playback/decoder behavior. The retained benchmark and tests use the actual
Foundation and Observation types, with no replacement implementations.

## What was expensive

[`AppModel.applyOpenRequest`](../Sources/IlliquidApp/App/AppModel.swift) adds each
prepared media item to the open-tab store synchronously on the main actor.
Two operations grew with all previously admitted tabs:

1. `OpenVideoTabs.add` searched the existing array using
   `MediaSource.representsSameResource`. Every comparison between valid local
   sources normalized both file URLs. Admitting N distinct local files therefore
   performed N(N-1) URL normalizations for duplicate detection, in addition to
   the initial playlist-item construction. At 1,000 files, duplicate detection
   alone required 999,000 normalizations.
2. Every successful store admission mapped the entire tab array into visible
   items and derived all titles again. N admissions constructed N(N+1)/2 visible
   items: 500,500 constructions for a 1,000-file selection.

The retained [original model](../Benchmarks/VideoTabAdmission/baseline/OpenVideoTabs.swift)
and [original store](../Benchmarks/VideoTabAdmission/baseline/OpenVideoTabStore.swift)
make those operations inspectable. This investigation targets admission and
resume bookkeeping. Other ongoing packet, subtitle, thumbnail, persistence, and
control-geometry investigations are outside this patch.

## Implementation

The resource index is private and derived from immutable open-tab sources:

- Local resources use exactly `NormalizedFileURL.persistenceKey(for:)`.
- Remote resources use exactly `url.absoluteURL.absoluteString`.
- Local and remote keys are distinct cases.
- An invalid directly constructed local source with a non-file URL has no key.
  Such values remain unindexed, preserving their existing nonmatching behavior.

Each addition now computes the incoming resource key once and performs an
expected constant-time dictionary lookup. Duplicate admissions retain the same
ID and resume state. Closing removes the key; reopening creates a fresh ID. The
index allocation is released when the last tab closes. Explicit equality still
compares `items` and `selectedID`, so cache capacity/history is not public state.

The observable store appends the one new immutable title/source projection after
either `add` or a first `record`. Updating an existing tab publishes no membership
change, as before. Closing retains the existing full membership reconstruction.
Selection, closing, and `record`'s UUID-position lookup still use ordered-array
scans; this patch does not claim that every tab operation is constant-time.

## Linux results

Environment: Swift 6.3.2, Linux x86_64/glibc 2.39, AMD EPYC 9V74 host. Both variants
were compiled as separate Swift modules with release `-O` and whole-module
optimization. Six samples alternate AB/BA equally for each scope and size.
Numbers are medians. Full ranges and individual observations are retained.

### Actual observable store: complete admission batch

| Files admitted | Original | Optimized | Comparison |
| ---: | ---: | ---: | ---: |
| 1 | 6.44 microseconds | 12.21 microseconds | +5.77 microseconds |
| 10 | 0.521 ms | 0.124 ms | 4.20 times faster |
| 100 | 50.43 ms | 1.355 ms | 37.22 times faster |
| 500 | 1,298.60 ms | 6.522 ms | 199.11 times faster |
| 1,000 | 5,033.10 ms | 13.177 ms | 381.95 times faster |

The 1,000-file store batch takes 99.738% less elapsed time in this component
benchmark. This is not a whole-player CPU or startup-latency measurement.

### Existing last tab, with 1,000 tabs open

| Operation | Original | Optimized |
| --- | ---: | ---: |
| Add the already-open resource | 9.973 ms | 9.464 microseconds |
| Record position/pause/playlist/folder | 9.945 ms | 10.257 microseconds |

The isolated core model shows the same scaling change: its 1,000-file batch falls
from 5,152.34 ms to 12.714 ms. Measuring the real observable store as well prevents
the result from overlooking its former repeated title projection.

Small-operation controls expose the cost of maintaining the index. Closing,
reopening, and selecting the sole tab changes from 6.66 to 17.16 microseconds
(+10.50 microseconds). With ten tabs, the same control improves from 100.42 to
21.36 microseconds. The few extra microseconds at one tab are acceptable for the
large reduction in multi-file admission and duplicate/update work.

Source: [grouped results](../Benchmarks/VideoTabAdmission/evidence/linux-x86_64/summary.json),
[408 raw observations](../Benchmarks/VideoTabAdmission/evidence/linux-x86_64/measurements.jsonl),
and [environment](../Benchmarks/VideoTabAdmission/evidence/linux-x86_64/environment.json).

## Correctness and measurement review

All **18 behavioral tests** passed against both original and optimized sources
in debug and release, for 72 test executions. The four suites include:

- A 17-by-17 equivalence matrix checked against the original linear
  `representsSameResource` comparison, including Unicode, dot segments, relative
  URLs, remote query/fragment/escaping distinctions, and invalid enum inputs.
- Three hundred seeded mixed operations checked against an independent linear
  model, including admission, selection, recording, closing, ordering, and
  neighbor navigation.
- Closing/reopening at every tested array position, independent copied values,
  semantic equality, original URL representation, and resume-state preservation.
- Observable-store membership notifications, quiet duplicate/update operations,
  immutable title/source projections, and previously retained array snapshots.

Every timed block is followed by a deterministic state checksum and assertions.
All 408 records match across original/optimized variants, repetitions, and the
core/store scopes. Random UUID values are excluded from cross-process checksums;
duplicate UUID stability and selection membership are checked separately.

Independent review verified the original files against the pinned Git revision,
examined the implementation and tests, and checked compiler flags and executable
loops. Real `add` and `record` calls remain inside the timed loops. The runner
verifies staged sources, package text, and executable hashes around execution.
The [test receipt](../Benchmarks/VideoTabAdmission/evidence/linux-x86_64/tests.json)
and [complete commands/output](../Benchmarks/VideoTabAdmission/evidence/linux-x86_64/commands.jsonl)
are retained with the source manifests and individual test logs.

## Boundaries and memory cost

These are synchronous component measurements with preconstructed synthetic
absolute local URLs and playlists. No filesystem access, file preparation,
SwiftUI layout/rendering, live UI observers, decoding, or visible playback occurs.
“Cold” means a new empty container; repeated small batches also include release
of the previous container. It does not mean a cold app launch or filesystem.

The ordinary admission loop does not retain every prior `items` array. A consumer
that holds an array snapshot can force an array copy on a later append. Snapshot
correctness is tested, but repeated snapshot retention is not the measured
admission workload. Consequently the result does not establish total time until
thousands of tabs are drawn in a real window.

The index adds one normalized resource key, one UUID, and dictionary storage per
distinct indexed open resource. It retains no media data and does not resolve
symlinks or cache filesystem metadata. Closing releases the removed key; closing
the final tab releases the index storage. Partial shrinkage may retain dictionary
capacity. Process RSS, allocation counts, and full-player memory savings were not
measured or claimed.

## Reproduce and qualify on macOS

```sh
python3 Benchmarks/VideoTabAdmission/run.py \
  --output /tmp/illiquid-video-tab-qualification --samples 6

# Run the same original/optimized behavioral suites without timing:
python3 Benchmarks/VideoTabAdmission/run.py \
  --output /tmp/illiquid-video-tab-tests --tests-only
```

See the [benchmark guide](../Benchmarks/VideoTabAdmission/README.md) for exact
source selection, retained baseline hashes, timer boundaries, and output files.
Builds use one job by default. An initial package-driver crash in the Linux
container was resolved by that build setting; no application code or platform
types were replaced to obtain these results.

The new [macOS workflow](../.github/workflows/video-tab-admission.yml) runs both
test configurations and the same six-sample measurements with Xcode 26.6 on
`macos-26`, archiving the evidence. The numeric results above are Linux results;
the initial PR run will provide separate native Foundation/Observation evidence.
Interactive multi-file opening and tab-strip rendering remain an end-to-end
macOS check, not a result inferred from the component benchmark.
