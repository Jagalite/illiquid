# Skip subtitle indexing when no subtitle files are supplied

## Finding

The external subtitle matcher built a filename-token index for every media URL
even when the subtitle input was empty. At that point the dictionary of original
media URLs to empty subtitle arrays was already the complete result. Returning it
after one final cancellation check removes the unnecessary tokenization, trie
construction, and empty-list sorting.

The production change adds six lines to
[ExternalSubtitleMatcher.swift](../Sources/IlliquidCore/Playlist/ExternalSubtitleMatcher.swift).
It adds no stored state or cross-call cache. The nonempty-subtitle path follows
the existing implementation.

[FolderPlaylistDiscovery.makePlaylist](../Sources/IlliquidCore/Playlist/FolderPlaylistDiscovery.swift)
calls this matcher after preparing its URL lists, including an empty subtitle
list. Therefore the shortcut removes work from the association portion of opening
or refreshing such a folder. Total discovery latency was not measured.

## Correctness and cancellation

Every original media URL remains a dictionary key, with an empty array as its
value. This includes unsupported media URLs and the original duplicate-key
behavior. Returning an empty dictionary immediately would violate that contract;
the shortcut runs after the existing initialization loop.

The initial and per-input cancellation polls remain. The final poll immediately
before returning discards all keys whenever it observes cancellation. Polls that
belonged to eliminated indexing and sorting work are intentionally absent; the
API does not promise an exact callback count.

The new regression file supplies eight test functions for empty and duplicate
inputs, unsupported media keys, cancellation before/during/after insertion,
one-shot and persistent cancellation across every observed checkpoint, and
nonempty matching/ambiguity/order. The existing 17-function matcher suite is
also retained. Both implementations run the same suites in debug and release.

Before timing, the driver compares 15 complete fixture outputs, including every
media URL key and the order of every associated-subtitle array. These fixtures
contain 13,114 output keys in total. Empty-subtitle fixtures additionally use an
independent oracle: keys must equal the set of original media URLs and all values
must be empty. Timed result-count checksums add a stability check; they do not
replace the full-output comparison.

## Experiment

- Baseline: complete production sources at
  [68274d1b09dcc866296321a5a8858efc297c4f19](https://github.com/Jagalite/illiquid/commit/68274d1b09dcc866296321a5a8858efc297c4f19).
  The runner verifies all three frozen files against their original Git blob IDs.
- Candidate: the complete current matcher and the unchanged MediaFileSupport
  and NaturalFilenameOrdering files.
- Separate optimized IlliquidCore libraries and separately compiled drivers use
  identical Swift 6, optimization, and whole-module-optimization flags. The
  production entry point remains across a module boundary.
- Each iteration performs one complete association call, consumes dictionary
  and subtitle counts, and destroys the returned result. Count consumption and
  loop overhead are included. Fixture generation, preflight, warmup, full-output
  serialization, and JSON encoding are outside the timers.
- Eleven workloads cover 0, 1, 16, 256, and 4,096 media URLs without subtitles;
  separate Unicode and longer-path fixtures; and nonempty supported/unsupported
  subtitle controls at 16 and 256 media URLs.
- Six pairs per case use fresh, serial processes and three AB plus three BA
  orders. Baseline process CPU calibration targets 150 ms and chooses identical
  iteration counts for both variants, rounded to multiples of 16.
- Both wall and process CPU time are recorded. No control time or outlier is
  subtracted. Repeated calls within one process are not independent samples.

The sample frequencies are deterministic research inputs, not measured user
traffic. URL preparation and static Foundation caches are warmed before timing.
The benchmark performs no directory enumeration, filesystem metadata reads,
subtitle parsing, or media decoding.

## Native qualification

The accepted run completed successfully on 2026-10-17:

- [GitHub Actions run 39073621804](https://github.com/Jagalite/illiquid/actions/runs/39073621804),
  job `117516148310`, attempt 1.
- Tested candidate commit:
  [775aa70d030364692be8a9a7782c66041cbcbf8b](https://github.com/Jagalite/illiquid/commit/775aa70d030364692be8a9a7782c66041cbcbf8b).
  Its working tree was clean.
- macOS 26.6.2 (25G83), arm64, Apple M1 (Virtual); Xcode 26.6;
  Apple Swift 6.3.3 (swiftlang-6.3.3.1.3), target arm64-apple-macosx26.0.
- All 25 component tests in two suites passed in each of four configurations:
  baseline debug, baseline release, candidate debug, candidate release.
  These are the isolated matcher suites, not the full application suite.
- Full baseline and candidate outputs matched for all 15 fixture records:
  13,114 media keys and 276 subtitle associations.
- Eleven calibration pilots and all 132 measured records were retained:
  eleven cases × six pairs × two variants.

### Empty subtitle inventory

Values below are medians of six process samples, normalized to one complete
association call. Reduction is `100 × (1 − candidate median / baseline median)`.
It is a ratio of marginal medians; the separately reported median of paired
ratios is a different statistic.

| Empty-subtitle input | Wall before → after (ms/call) | Wall reduction | CPU before → after (ms/call) | CPU reduction | Faster wall / CPU pairs |
| --- | ---: | ---: | ---: | ---: | ---: |
| 0 media | 0.000165 → 0.000080 | 51.72% | 0.000165 → 0.000079 | 51.93% | 6/6 · 6/6 |
| 1 media | 0.0167 → 0.000474 | 97.17% | 0.0163 → 0.000467 | 97.13% | 6/6 · 6/6 |
| 16 media | 0.2457 → 0.0101 | 95.90% | 0.2354 → 0.0101 | 95.71% | 6/6 · 6/6 |
| 256 media | 3.364 → 0.1477 | 95.61% | 3.362 → 0.1479 | 95.60% | 6/6 · 6/6 |
| 4,096 media | 55.889 → 3.081 | 94.49% | 55.841 → 3.058 | 94.52% | 6/6 · 6/6 |
| 4,096, Unicode | 72.243 → 3.445 | 95.23% | 72.147 → 3.443 | 95.23% | 6/6 · 6/6 |
| 4,096, long paths/names | 155.303 → 11.209 | 92.78% | 139.413 → 10.008 | 92.82% | 6/6 · 6/6 |

The representative 4,096-file ASCII case saved **52.807 ms per association
call**, reducing median wall time from **55.889 ms to 3.081 ms (94.49%)**.
Process CPU time fell from 55.841 ms to 3.058 ms (94.52%). Every empty-inventory
case was faster in all six wall-time pairs and all six CPU-time pairs.

For nonzero empty-inventory fixtures, median wall reductions ranged from
92.78% to 97.17%. The remaining work still initializes and returns the dictionary
and polls cancellation. It is linear in the input size; this change does not
make association constant time.

### Nonempty subtitle controls

These inputs continue through the original matching path after the new
emptiness check. A positive reduction is faster; a negative reduction is slower.
A paired candidate/baseline ratio below one is faster.

| Nonempty-subtitle control | Wall before → after (ms/call) | Wall reduction | CPU reduction | Paired wall ratio median [min, max] | Faster wall pairs |
| --- | ---: | ---: | ---: | ---: | ---: |
| 16 media + 16 supported subtitles | 0.4383 → 0.4082 | 6.86% | 7.28% | 1.0930 [0.7846, 1.2579] | 2/6 |
| 256 media + 256 supported subtitles | 6.084 → 6.081 | 0.04% | −0.04% | 0.9987 [0.9501, 1.1035] | 3/6 |
| 16 media + 16 unsupported subtitles | 0.2252 → 0.2070 | 8.06% | 8.41% | 0.9514 [0.8825, 1.1552] | 3/6 |
| 256 media + 256 unsupported subtitles | 2.827 → 3.158 | −11.73% | −12.00% | 1.0326 [0.9502, 1.3865] | 3/6 |

The controls do **not** establish performance equivalence. In particular,
`unsupported_256` had an 11.73% higher median wall time and a 12.00% higher median
CPU time. Its paired wall median ratio was 1.0326, with three of six pairs faster.
For `supported_16`, the 6.86% favorable marginal-median reduction coexists with
a 1.0930 paired median ratio and only two of six faster pairs. That disagreement
is why both statistics and every observation are retained.

The virtualized host showed variation across unchanged-path controls.
This experiment does not identify the cause of that variation or rule out a
small nonempty-path cost from the added branch. The narrow empty-inventory
finding is supported by a large reduction and consistent paired results;
the nonempty controls support no claim of speedup or proven neutrality.
No unfavorable measurement was excluded and no follow-up run was selected
to replace this campaign.

### Pair distributions and calibration

The same iteration count is used by both implementations for a case.
Each case has three baseline-first and three candidate-first pairs.
Four warmup calls precede each measured process sample.

| Case | Iterations per sample | Wall candidate/baseline paired median [min, max] | CPU candidate/baseline paired median [min, max] |
| --- | ---: | ---: | ---: |
| `empty_0` | 369,232 | 0.4522 [0.4149, 0.5480] | 0.4533 [0.4163, 0.5476] |
| `empty_1` | 12,096 | 0.0294 [0.0233, 0.0505] | 0.0295 [0.0231, 0.0495] |
| `empty_16` | 864 | 0.0393 [0.0363, 0.0497] | 0.0413 [0.0371, 0.0506] |
| `empty_256` | 48 | 0.0463 [0.0383, 0.0600] | 0.0464 [0.0384, 0.0601] |
| `empty_4096` | 16 | 0.0551 [0.0401, 0.0815] | 0.0548 [0.0400, 0.0815] |
| `empty_unicode_4096` | 16 | 0.0491 [0.0444, 0.0536] | 0.0496 [0.0445, 0.0537] |
| `empty_long_4096` | 16 | 0.0719 [0.0680, 0.0946] | 0.0708 [0.0626, 0.0759] |
| `supported_16` | 448 | 1.0930 [0.7846, 1.2579] | 1.0843 [0.8077, 1.1743] |
| `supported_256` | 32 | 0.9987 [0.9501, 1.1035] | 0.9999 [0.9518, 1.1029] |
| `unsupported_16` | 960 | 0.9514 [0.8825, 1.1552] | 0.9510 [0.8782, 1.1548] |
| `unsupported_256` | 48 | 1.0326 [0.9502, 1.3865] | 1.0318 [0.9508, 1.3876] |

Calibration targets 150 ms of baseline CPU time with a minimum of 16 iterations.
It does not promise 150 ms for the much faster candidate. For example, small
candidate inputs have short measured batches, so tiny-input estimates are more
sensitive to clock and scheduling effects; the shortest candidate batch was
5.13 ms. One long-path candidate sample had approximately 1.98 times as much
wall time as process CPU time. At the other extreme, the 16-iteration
minimum makes large baseline batches longer than the target. Full sample
ranges and elapsed integer clock values are available in the evidence.

## Evidence and reproduction

The committed evidence is independent of the expiring Actions artifact:

- [Complete qualification ZIP](../Benchmarks/EmptySubtitleAssociation/evidence/macos/qualification.zip):
  exact 142,463-byte archive produced by the native job; 28 entries containing
  both source snapshots, driver/runner/test inputs, four test logs, four build
  logs, full baseline and candidate fixture outputs, calibration, all raw
  measurements, summaries, metadata, and command receipts.
- [Run and archive provenance](../Benchmarks/EmptySubtitleAssociation/evidence/macos/provenance.json).
- [Readable manifest](../Benchmarks/EmptySubtitleAssociation/evidence/macos/manifest.json),
  [all raw measurements](../Benchmarks/EmptySubtitleAssociation/evidence/macos/measurements.jsonl),
  [summary](../Benchmarks/EmptySubtitleAssociation/evidence/macos/summary.json),
  [parity receipt](../Benchmarks/EmptySubtitleAssociation/evidence/macos/parity.json),
  and [result receipt](../Benchmarks/EmptySubtitleAssociation/evidence/macos/result.json).
- [Benchmark instructions](../Benchmarks/EmptySubtitleAssociation/README.md).

Archive SHA-256:
`e833f7a9fe23d0da9957873d6cc45b68c06b01a7858b8092bb4092e959c676cd`.

Full-output canonical parity SHA-256:
`c5b5fb5d105f3e4d9c31c098f7994e46a6d81679c0cf07bffa7c190bdb8e2702`.

The archive was decoded and audited independently: its SHA-256 and all entry
CRC32 values matched; all integer checksums, timing divisions, pair order,
medians, ranges, and ratio calculations were recomputed. All 161 archived
command receipts have exit status zero, and all archived production/test/harness
source hashes match the recorded inputs. Full fixture outputs
also matched independently generated exact URL-to-subtitle mappings.

The later evidence/report commit preserves the tested production, test, driver,
and runner bytes. Its workflow cleanup removes the temporary branch-specific
push trigger and qualification-only base64 log output; pull-request/manual runs
retain the same test and six-pair benchmark command and ZIP artifact upload.

To reproduce with one Swift 6.1+ toolchain and Python 3.9+, from the repository
root and with an empty output directory:

```sh
python3 Benchmarks/EmptySubtitleAssociation/run.py \
  --output /tmp/illiquid-empty-subtitle-association --pairs 6
```

Use `--mode tests` for the isolated regressions or `--mode benchmark` for parity
and timing. Performance numbers are recorded for review, not enforced as a
timing threshold in CI.

## Scope and related work

This is a component result. It measures the association stage after URL lists
have been prepared; it does not measure filesystem enumeration, total folder
open/refresh time, cold startup, UI responsiveness, playback frame rate, memory
allocation, retained memory, or battery use. The long-path fixture is synthetic
and does not access those paths on disk. No workload-frequency claim is made.

The full application build and full application suite are outside this
qualification; the repository's normal PR checks report integration status
separately.

Concurrent work on
[`perf/empty-subtitle-association`](https://github.com/Jagalite/illiquid/tree/perf/empty-subtitle-association)
at [7062f5285ee4c91a2a1ce72d855c6d53365b25c6](https://github.com/Jagalite/illiquid/commit/7062f5285ee4c91a2a1ce72d855c6d53365b25c6)
contains the same production shortcut. This branch is an independently validated
alternative with an isolated component benchmark and preserved native evidence.
The performance gains are not cumulative; these branches should be reconciled
as alternatives because their benchmark and workflow paths also overlap.
