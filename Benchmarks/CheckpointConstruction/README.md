# Playback checkpoint construction

## Question

Can a checkpoint avoid a playlist membership scan when its captured index
already identifies the current source, without changing the saved session?

The baseline is integrated main at
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`.
The writer checks folder membership with a linear sequence of normalized URL
comparisons. It also does that work when the captured folder is nil.
Checkpoints run every ten seconds of playback progress and at several pause,
seek, playlist, and lifecycle boundaries.

The candidate skips membership work for a nil folder, and validates an in-bounds
captured index beyond the first item using the existing identity predicate.
A matching item proves membership. Index zero uses the original scan, which
already stops at the first match; this avoids checking its item twice on a miss.
A missing, invalid, or stale index also falls back to that scan.
The saved index, playlist deduplication, all other record fields, and the
persistence schema are unchanged.

## Reproduction

The native mode requires macOS 26 and Swift 6.1 or newer and uses Xcode 26.6
in CI. An explicit Linux component mode uses the official Swift 6.3.2 image.
From the repository root:

```sh
git fetch --no-tags --depth=1 origin ea2ff568237e2667f7b1aeee67b11a44ebe95b72
python3 Benchmarks/CheckpointConstruction/run.py \
  --pairs 8 --target-ms 150 --output /tmp/illiquid-checkpoint-study
```

On Linux, add `--portable`. This stages the unchanged complete
PlaybackSessionRecord type and PlaybackSessionStoring protocol up to the checked
atomic-store declaration boundary. The unrelated atomic file-store class,
its lifecycle/migration dependencies and its test suite are omitted. The
checkpoint writer itself remains a complete, byte-for-byte production file.
The manifest records both full-file and actually compiled source hashes.
This mode qualifies the component on Linux, not native macOS behavior.

Use a new output directory. Add `--tests-only` to run debug/release
regressions and complete-record differential verification without timings.

When the shared Kyoto queue is available, submit the intended Python command
through it, as required by `AGENTS.md`. The hosted macOS workflow checks for
the queue and otherwise builds its isolated packages serially.

## Method

The runner stages separate Swift packages with complete, byte-for-byte production
files from the pinned baseline and candidate checkout. Native mode does not
extract or rewrite declarations; Linux uses only the record/protocol boundary
described above, without modifying either declaration. Nine shared Core sources must be unchanged,
and both packages use the same driver and tests with no external dependencies.
The complete checkpoint writer is compiled in an IlliquidPlayer module.
Release builds use SwiftPM's optimization settings; testability is enabled so
the separate driver can exercise the internal checkpoint value.

Both variants run the existing session-store, playlist-mutation, folder-playlist,
and core-utility tests, plus the checkpoint regression suite, in debug and release. Linux omits the
atomic session-store suite; all checkpoint regressions remain enabled.
The driver then checks 1,155 cases against the original membership predicate
and initializer. Only updatedAt is normalized for comparison. Every complete
encoded record is compared across binaries, not only a checksum. Coverage
includes duplicates and metadata, decoded aliases, Unicode, dot segments,
localhost and rejected authorities, malformed source enum/URL combinations,
nonfinite positions, and missing or extreme indices.

There are 33 timing workloads:

- First, middle, and last indexed hits at 16, 256, and 1,024 items.
- Nil folder, nil index, stale index, out-of-range index, missing source, and
  remote-source controls at each size.
- A stale index with a first-item hit at each size, exposing the extra failed
  comparison before the fallback's early return.
- Singleton hit and miss, and an empty playlist.

Each workload has eight fresh-process pairs, balanced AB/BA. Workload order
rotates between rounds. Baseline calibration targets 150 ms of process CPU time;
the resulting iteration count is shared by both variants. Four warmup calls in
every process and all calibration observations are excluded. Deterministic
hashing is enabled for both variants.

Both process CPU and monotonic wall time cover the complete production
record() operation, including playlist deduplication, Date() creation,
result consumption, and release. Fixture creation, independent expected results,
JSON encoding, and complete-record comparison are outside timing. The driver
checks full output before and after each timed sample and validates every
sample's checksum.

The primary statistic is the median within-pair candidate/baseline CPU ratio.
Negative percentage changes mean less time. Independent absolute medians and
all ranges are also retained; their ratio need not equal the paired statistic.
No timing threshold gates CI and no observations are discarded.

## Evidence and limits

The runner writes compiler/host/source/binary receipts, commands, all test logs,
complete verification outputs, calibration, every timed observation, and the
summary. The workflows retain these as Actions artifacts. The portable PR job runs
tests and complete-record parity; push/manual research runs also collect timings. Results and their
interpretation are recorded after qualification in
[the study report](../../Documentation/CHECKPOINT_CONSTRUCTION_PERFORMANCE.md).

These are warm component measurements of checkpoint construction. The full
record still performs O(n) deduplication. The experiment does not measure JSON
encoding, atomic file writes, the coalescing writer, macOS window latency,
media decoding, frame rate, battery use, or end-to-end shutdown. The checkpoint
runs off the main actor. Workload frequencies and typical user playlist sizes
have not been measured. The timed loop has no per-call autorelease pool, so
Foundation temporaries may survive across calls within one sample process.
A stale positive index may add one failed identity comparison
before the existing scan; the controls quantify that tradeoff.
