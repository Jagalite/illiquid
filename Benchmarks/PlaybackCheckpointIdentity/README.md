# Playback checkpoint identity allocation research

## Finding and change

`PlaybackCheckpoint.record()` previously called
`NormalizedFileURL.representsSameFile(item.url, source.url)` for each visited
playlist item. That re-created the same normalized source identity during every
comparison. It also searched the playlist when `folder == nil`, even though the
membership result could not affect the persisted collection folder.

The candidate skips membership work when the folder is absent, and computes the
source key once before a folder-backed membership scan. Each visited item still
uses the existing normalized persistence key. There is no retained identity
cache, new state, or change to persistence format, checkpoint scheduling, or the
writer queue.

This path is exercised when playback state is checkpointed, including position
changes and lifecycle/playlist transitions. The position condition is at least
10 seconds of playback-position movement since the previous checkpoint; it is
not a 10-second wall-clock timer. Multifile/appended playlists can have no folder,
so the skipped scan is a real application path.

The complete record constructor still deduplicates the playlist and remains
O(n). This change reduces redundant transient allocation and normalization work;
it does not make complete checkpoint construction constant time.

## Recorded Linux experiment

Baseline revision: `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`.
Compiler: Swift 6.3.2 on Linux/Ubuntu 24.04. The complete run used six alternating
AB/BA process pairs and an 80 ms calibration target. It completed 324 timing
observations and 324 allocation observations across 27 cases.

**Evidence status:** the completed run was checked before publication, but its
raw receipts were lost when the execution workspace reset. The table below is
the retained result summary, not an archived raw dataset. The reviewed source,
tests, and harness were recovered. The PR workflow regenerates complete
receipts on Linux and macOS; those new runs record their own compiler/platform
and must be assessed separately.

Results per complete record, for a 10,000-item playlist:

| Scenario | Baseline allocation requests | Candidate allocation requests | Fewer requests | Baseline median ms | Candidate median ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| No folder; source last | 780,014 | 260,014 | 66.7% | 181.79 | 56.94 |
| First item (control) | 260,066 | 260,066 | 0% | 58.16 | 62.30 |
| Middle item | 520,066 | 390,066 | 25.0% | 105.65 | 84.69 |
| Last item | 780,014 | 520,040 | 33.3% | 151.47 | 137.03 |
| Missing local source | 770,014 | 520,039 | 32.5% | 157.86 | 107.59 |
| Remote source (control) | 260,014 | 260,014 | 0% | 60.55 | 59.18 |

Allocation counts were identical across all six repeats for each variant/case.
Requested allocation bytes fell from 66,640,288 to 22,564,728 for the no-folder
case, and from 66,640,288 to 44,602,492 for the last-item case.

Timing was noisy on the shared host. No-folder ranges were 147.42–209.06 ms
(baseline) and 51.80–82.88 ms (candidate). Last-item ranges were 146.71–194.79 ms
and 104.48–170.11 ms. The controls' timing ranges overlapped; there is no claimed
control-path or universal speedup. Ratios of these medians are distinct from the
harness's median of paired percentage changes.

These are allocation **requests and requested bytes**, not live heap, peak
memory, retained memory, RSS, GPU memory, or full-player energy/CPU measurements.
The interposer counts successful malloc/calloc/realloc requests on Linux/glibc.
It does not measure macOS allocation traffic. Timing runs do not preload it.

## Qualification method

The harness stages the actual production checkpoint source and six unchanged
production Core dependencies. Both variants share those exact Core bytes.
`baseline/manifest.json` pins their SHA-256 and Git blob identities and the
original checkpoint file. A changed dependency causes a failure rather than
silently changing the comparison.

For `PlaybackSessionStore.swift`, it retains the exact record/protocol prefix
and excludes the unrelated disk store at one checked source boundary. This is
an isolated component build; it does not replace full application compilation.

The benchmark builds optimized Core and Player modules separately, with no
cross-module optimization. An out-of-line driver calls the production record
constructor and consumes the result. The measured interval includes identical
small observation work (count/folder reads and one varying URL's string length).
Fixture creation, canonical JSON serialization, disk I/O, and output writing are
outside that interval.

The fixture matrix uses playlist sizes 0, 1, 10, 1,000, and 10,000 with no-folder,
first, middle, last, missing, and remote scenarios. Only the meaningful no-folder,
missing, and remote cases are used for an empty playlist: 27 cases in total.

Each fresh process checks the complete canonical record against independently
known fixture expectations before and after measurement. Only the volatile
`updatedAt` field is normalized. Cross-variant checksum, record fingerprint,
record length, workload, and iteration counts must match. Allocation runs also
match their one-iteration calibration receipts. Missing allocation-meter symbols
or invalid counts fail the run.

Six regression tests cover every membership position, absent/empty inputs,
canonical path aliases and Unicode, unsupported authorities and remote URLs,
the legacy URL-based MediaSource contract, deduplication metadata, immutable
snapshots, and serialization. They passed on both baseline and candidate in
debug and release in the recorded run: four runs, 24 test executions.

## Reproduce

Use Swift 6.1 or newer, Python 3, and a C compiler for the Linux allocation probe.
Run builds through the shared Kyoto queue when it is available, as required by
`AGENTS.md`. Kyoto was unavailable in the research environment. A local queued
invocation is:

```sh
python3 /Volumes/seed1/Projects/kyoto/kyoto.py submit -- \
  python3 Benchmarks/PlaybackCheckpointIdentity/run.py \
  --output /tmp/playback-checkpoint-identity --pairs 6 --target-ms 80
```

When that queue is unavailable, use the same Python command directly with an
isolated, new output directory. Use `--swift /path/to/swift` to choose a toolchain.
For a correctness-only pass, add `--tests-only`. `--quick` limits the fixture
sizes; `--skip-tests` is available for repeated measurement after qualification.

The runner refuses a nonempty output directory. Review `completion.json`,
`tests.json`, `manifest.json`, `summary.json`, `allocations.json`,
`observations.jsonl`, and `allocation-observations.jsonl` (Linux/glibc).
`commands.jsonl`, `logs/`, and `sources/` retain command receipts, compiler/test
output, and exact source snapshots. `.work/` contains disposable build files.

The PR workflow runs the component tests and timings on macOS, and repeats the
tests/timings plus the allocation probe on Linux. CI uses the runner's installed
toolchain and records it in the manifest. It archives receipts and source
snapshots as workflow artifacts. There is no timing threshold on shared CI.
Native macOS allocation profiling and full-player playback/UI qualification
remain outside this component experiment.

## Source references

- [Production checkpoint baseline](https://github.com/Jagalite/illiquid/blob/ea2ff568237e2667f7b1aeee67b11a44ebe95b72/Sources/IlliquidPlayer/Player/PlaybackCheckpointWriter.swift).
- [Pure lexical URL identity implementation](https://github.com/Jagalite/illiquid/blob/ea2ff568237e2667f7b1aeee67b11a44ebe95b72/Sources/IlliquidCore/Utilities/NormalizedFileURL.swift).
- [Record construction and deduplication](https://github.com/Jagalite/illiquid/blob/ea2ff568237e2667f7b1aeee67b11a44ebe95b72/Sources/IlliquidCore/Persistence/PlaybackSessionStore.swift).
- [Swift allocation profiling guidance](https://www.swift.org/documentation/server/guides/allocations.html).
