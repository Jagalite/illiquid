# Playback checkpoint membership performance

## Draft status

**Revised candidate `582685bd7f1d938b6ccae6bffff4cd138ab5a00f` is not yet
natively qualified or measured.**
[Run 40637204455](https://github.com/Jagalite/illiquid/actions/runs/40637204455)
remained queued after more than 23 minutes at preparation. Planned: 16 pairs per
workload, 200 ms calibration target. Every result below belongs to the first candidate.

## Problem and change

[PlaybackCheckpoint.record()](../Sources/IlliquidPlayer/Player/PlaybackCheckpointWriter.swift)
establishes playlist membership before saving the collection folder. The baseline
scans preceding items with `NormalizedFileURL.representsSameFile`, repeatedly
normalizing both the item URL and the unchanged source URL. It ignores the
already-captured selected index.

The revision validates an in-bounds selected item first using the existing
identity helper. Missing, invalid, or stale indices
fall back to a scan with one cached source identity. A missing collection folder,
non-file source URL, or empty playlist needs no membership search. There is no
persistent cache or change to the saved index, playlist order, or record schema.

[PlaybackController](../Sources/IlliquidPlayer/Player/PlaybackController.swift)
captures checkpoints on pause transitions and after playback position changes
by at least ten seconds, as well as playlist/lifecycle changes. Construction runs
on the coalescing writer queue. A successful selected-index membership check is
O(1) in playlist length; the complete checkpoint remains O(n), because the real
[record initializer](../Sources/IlliquidCore/Persistence/PlaybackSessionStore.swift)
still deduplicates the playlist and JSON encoding still traverses it.

## Baseline and experimental decision

The frozen baseline is commit `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`.
[The manifest](../Benchmarks/PlaybackCheckpoint/baseline/manifest.json) pins its
Git blob and SHA-256; altered bytes are rejected.

The first candidate, commit `48b86dd8ca2c9c7f8c33a673692ea3311001d771`, normalized
the source before the selected-item comparison. In
[run 40635351929](https://github.com/Jagalite/illiquid/actions/runs/40635351929),
eight pairs with an 80 ms calibration target showed substantial large-playlist
improvements, but `encode-singleton-1` regressed by **12.3% median paired wall
time and 11.8% CPU time**, with the candidate slower in seven of eight pairs.
That control result prompted the revision and is retained in the evidence.

The revision reuses `representsSameFile` on the selected-index path and caches
the source key only for fallback scans. A stale hint can incur one extra source
normalization. This response to the adverse control is unproven; do not combine
the candidate versions or cohorts.

## Correctness and measurement

The exploratory run used macOS 26.6.2 on arm64, Xcode 26.6, and Apple Swift
6.3.3. Both variants compiled against the same separately optimized `IlliquidCore`
library containing eight unchanged production files. Each checkpoint writer
and identical driver compiled separately with `-O -whole-module-optimization`;
there is no cross-module optimization, extracted production code, or substitute
record/URL implementation.

The exploratory run passed **21 tests in two suites**, baseline and first
candidate, debug and release: four successful configurations. Its 224 deterministic
combinations compare complete records and exact sorted-key JSON bytes after fixing
`updatedAt`. Coverage includes invalid and stale indices, decoded lexical and
Unicode aliases, unsupported authorities/credentials/ports, duplicate metadata,
nonfinite positions, and snapshot independence. Malformed source enum labels
retain the original URL-based membership policy. These passes do not qualify
the revised candidate.

The **26 workloads** measure complete record construction and construction plus
sorted-key JSON encoding across thirteen fixtures. Sizes are 0, 1, 32, 1,000,
and 10,000 entries, with front/middle/last hits and missing/stale/out-of-range
indices, absent/remote sources, and nil-folder controls. The 10,000-entry cases
stress scaling. Synthetic URLs, timestamps, and occasional subtitles retain
realistic record structure.

The completed protocol used eight adjacent pairs per workload and an 80 ms
baseline calibration target; the pending run increases these to 16 pairs and
200 ms. Both use identical iteration counts within each pair, alternating AB/BA
order, and reversed case traversal. Each observation starts a fresh process.
Fixture construction, two warmups, output checks, hashing, and receipts are
outside timing. A constant-cost checksum consumes every result; full outputs
are checked before and after measurements.
`DispatchTime` measures elapsed time and `CLOCK_PROCESS_CPUTIME_ID` measures
process CPU. All samples are retained; summarization verifies ordering,
completeness, iteration counts, checksums, and output fingerprints.

## Exploratory results: first candidate only

Results below are from commit `48b86dd8ca2c9c7f8c33a673692ea3311001d771`.
The [complete summary](../Benchmarks/PlaybackCheckpoint/evidence/exploratory-macos/timing-summary.json)
contains all 26 workloads and every paired ratio.

| Workload | Baseline median ms/op | First candidate median ms/op | Median paired wall change | Median paired CPU change |
|---|---:|---:|---:|---:|
| `record-last-1000` | 15.0514 | 6.9306 | -62.3% | -63.8% |
| `encode-last-1000` | 14.6169 | 6.7163 | -54.0% | -53.9% |
| `record-last-10000` | 143.9891 | 41.0331 | -68.4% | -67.7% |
| `encode-last-10000` | 157.9831 | 73.3445 | -53.5% | -53.5% |
| `record-stale-index-1000` | 15.2801 | 9.4856 | -36.1% | -35.0% |
| `record-singleton-1` | 0.0101 | 0.0109 | +4.8% | +3.7% |
| `encode-singleton-1` | 0.0232 | 0.0286 | +12.3% | +11.8% |
| `encode-front-32` | 0.3120 | 0.3291 | +6.3% | +1.6% |
| `record-front-10000` | 48.4836 | 43.3296 | +0.2% | -3.0% |
| `encode-remote-1000` | 7.2166 | 7.1966 | -1.2% | -0.4% |

Milliseconds are each variant's marginal median. Percentage change is
`100 × (median(candidate / baseline within each pair) − 1)` and need not equal
the ratio of those marginal medians. Negative changes mean less time. Scopes
were timed independently; subtracting record rows from encoding rows does not
isolate encoding cost.

### Remaining draft qualification

- [ ] Revised candidate passes baseline/candidate debug and release tests.
- [ ] Exact output parity and all 16-pair, 26-workload receipts are validated.
- [ ] Singleton, front-hit, and remote controls are assessed alongside target
  gains before deciding whether the revision is ready for review.

## Reproduce and inspect

On macOS with Xcode and Python 3.10+:

```sh
python3 Benchmarks/PlaybackCheckpoint/run.py \
  --pairs 16 --target-ms 200 --output /tmp/playback-checkpoint
python3 Benchmarks/PlaybackCheckpoint/run.py \
  --mode summarize --output /tmp/playback-checkpoint
```

Use a new or empty output directory. Follow [AGENTS.md](../AGENTS.md): use Kyoto
when available; hosted runners record its absence and build serially in isolation.
The [benchmark README](../Benchmarks/PlaybackCheckpoint/README.md) describes narrower modes.

The existing
[`evidence/exploratory-macos`](../Benchmarks/PlaybackCheckpoint/evidence/exploratory-macos/)
directory retains first-candidate source/provenance, commands, test logs,
calibration, observations, verification receipts, summaries, and compressed
`review-bundle.json.gz`. The completed workflow artifact also contains full source
snapshots and complete-output records. The final run's artifact link and results
remain pending; no final artifact is available yet.

These measurements cover native Foundation component work. Encoding excludes
the store lock, directory creation, and atomic disk write. They establish no
whole-application, visible UI, playback throughput, disk-I/O, or energy result;
full application builds and live playback qualification remain separate.
