# Checkpoint zero-index hint control

## Recorded result

The direct Linux comparison passed all four debug/release test configurations and
1,158 complete-record equivalence checks. The missing singleton used 33.87% less
CPU time, and the two-item stale/missing-zero workloads used 16.60–16.67% less
by the median paired ratio. All eight pairs improved in those three workloads.
The 17 control medians ranged from -0.56% to +1.53%, with noisy individual pairs.
Native macOS validation remains pending; this is a narrow draft follow-up.
See [the complete results, limits and provenance](RESULTS.md) and
[raw Linux receipts](evidence/linux/).

## Scope and relationship to existing work

This is a focused follow-up to [PR #140](https://github.com/Jagalite/illiquid/pull/140),
which is itself stacked on [PR #124](https://github.com/Jagalite/illiquid/pull/124).
The baseline is #140's head at
`2620d561d11c9a7d9396d3b455424a10a6dddcd7`.
The broader checkpoint optimization, source-key reuse and verified positive-index
shortcut belong to those PRs. Their previously reported improvements are not
evidence for this additional change.

The new production change adds `index > 0` to the hint condition.
A zero hint is already the first item visited by the fallback. Trying it first
and then retrying it in the scan normalizes that item twice when it does not
match. The guard avoids this redundant attempt while preserving source-key reuse,
the positive-index shortcut, the original normalized fallback, saved fields,
deduplication and schema.

For a missing singleton with hint zero, complete construction normalizes the
source once and its only item twice in the baseline, versus the source and item
once each in the candidate. For n >= 2 unique supported items with a full miss
or last-item match and stale hint zero, the total identity work including
deduplication changes from 2n + 2 normalizations to 2n + 1.
The benefit therefore diminishes with playlist size. Matching zero hints have
the same identity work, and normal matching positive hints retain their shortcut.
The frequency of stale zero hints in real sessions has not been measured.

## Reproduction

On macOS 26 with Swift 6.1 or newer:

```sh
git fetch --no-tags --depth=1 origin 2620d561d11c9a7d9396d3b455424a10a6dddcd7
python3 Benchmarks/CheckpointHintControls/run.py \
  --pairs 8 --target-ms 250 --output /tmp/illiquid-checkpoint-hint-controls
```

Use a new output directory. Add `--portable` on Linux, or
`--tests-only` for correctness qualification without timings.
The Linux workflow pins the official Swift 6.3.2 Ubuntu 24.04 image by digest.
The native workflow uses Xcode 26.6. Use the shared Kyoto queue when available,
as required by `AGENTS.md`; hosted runners record its absence and build
isolated packages serially.

## Actual production inputs and correctness

Both variants compile the complete production checkpoint writer in a separate
IlliquidPlayer module. The nine shared Core files must be byte-identical.
macOS compiles all of those files. Linux retains the exact complete
PlaybackSessionRecord and PlaybackSessionStoring declarations before a checked
atomic-store boundary; it omits the unrelated atomic file-store class, its
lifecycle/migration dependencies and its tests. Full-file and compiled-source
hashes are recorded separately.

The existing #140 checkpoint regression suite is reused unchanged, alongside
playlist-mutation, folder-playlist and core-utility tests. Native mode also runs
the atomic session-store suite. Both variants run debug and release tests.

The driver independently checks 1,158 records against the original existential
membership rule and record initializer, comparing complete encoded records
across variants after normalizing only updatedAt. Coverage includes the
parent's index behavior, missing and extreme hints, duplicates and metadata,
decoded aliases, Unicode, dot segments, localhost and unsupported authorities,
malformed source enum/URL combinations, and nonfinite positions.
No production tests are replaced or weakened.

## Timing protocol

There are 24 fixed workloads: seven affected cases and seventeen controls.
Affected cases are a missing singleton with hint zero, and stale-zero late hits
and missing sources at 2, 8 and 32 items. Controls cover matching zero/positive
hints, first/middle/last selection, stale positive hints, missing or out-of-range
indices, absent folders, remote sources, and empty playlists.

Each workload has eight fresh-process pairs, balanced AB/BA, with workload order
rotated between rounds: 384 timed observations. Baseline calibration targets
250 ms of process CPU time and chooses a common iteration count for both
variants. Calibration and four warmup calls per process are excluded.
All measured samples are retained; no timing threshold gates CI.

CPU and monotonic wall time cover complete record() construction, including
unchanged deduplication, Date() creation, minimal result consumption and release.
Input generation, independent expected output, JSON encoding and full-record
comparison are outside timing. Full results are checked before and after
every sample, and each timed checksum is verified.

The main statistic is the median within-pair candidate/baseline CPU ratio.
Negative percentage changes mean less time. Absolute medians and full paired
ranges are also reported; the ratio of separate medians can differ from the
paired statistic. Raw observations, calibration, commands, source/compiler/binary
receipts and test logs are retained in workflow artifacts.

## Qualification limits

The initial broad main-versus-index-shortcut research overlapped concurrent
PRs #124, #140 and #168. No competing broad PR is proposed. This study compares
only the additional zero-index guard with #140's exact existing implementation.

Linux component results cannot establish macOS performance. Native checks and
measurements remain separate. The complete record operation is still O(n).
The experiment excludes encoding, atomic writes, queue delay, playback, UI
latency, energy use and whole-player CPU/memory. The warm loop has no per-call
autorelease pool; it is not a physical-memory measurement.

A positive result must be assessed against the matching-hint controls, since
the affected stale/missing states are narrow. No broad checkpoint speedup or
fix for #168's matching-singleton encoding result should be inferred from this
guard alone.
