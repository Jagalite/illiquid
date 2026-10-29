# Verified checkpoint index: performance research

This experiment compares the complete `PlaybackCheckpoint.record()` operation
against the normalized membership scan introduced by [PR #124](https://github.com/Jagalite/illiquid/pull/124),
pinned at `9f21c84bbe097984642c8fc08b7c8c1fd31a6c41`.

The candidate treats the captured playlist index as a hint. It checks bounds
and normalized file identity before accepting it; otherwise it retains the
normalized scan. Session-record deduplication still runs, so complete construction
remains linear in playlist length. This is a follow-up to #124, not a duplicate
claim for skipping no-folder scans or hoisting source normalization.

## Reproduce

```sh
python3 Benchmarks/CheckpointIndexHint/run.py \
  --pairs 8 --target-ms 40 --output /tmp/checkpoint-index-hint
```

The output directory must be new or empty. `--tests-only` runs the four
baseline/candidate debug/release configurations without collecting timings.
Use a Swift toolchain supporting package tools 6.1 and bundled Testing.

Where Kyoto is available, submit this entire command through the shared queue
described in `AGENTS.md`, then inspect its show/logs/wait receipts. Hosted runners
have no Kyoto mount. The harness serializes builds in separate package directories.

## Method and scope

Both variants use the same six supporting production files. From
`PlaybackSessionStore.swift`, the harness retains the exact complete record and
storage-protocol declarations and excludes the unrelated atomic I/O store.
The declaration bodies and imports remain unchanged; the original full-file
hash and all compiled source hashes are recorded. No mock implementation
replaces a measured production method.

Each optimized driver calls the production checkpoint module across a compilation
boundary without cross-module optimization. Fixtures and record JSON encoding
run outside timing. A deterministic FNV-1a fingerprint compares each complete
warmup record after fixing only its timestamp. Every timed return contributes
to a checked checksum. The independent regression suite compares complete
records and JSON round trips with explicitly labeled identity expectations.

The 23 workloads cover empty/singleton controls, first/middle/last hits,
32/1,000/10,000 items, absent/stale/invalid hints, missing targets, no folder,
Unicode paths, duplicate metadata, remote sources, and unsupported local URLs.
Baseline calibration chooses a shared iteration count per workload. Eight
fresh-process pairs alternate baseline-first and candidate-first order.
All samples are retained; reports include medians, ranges, paired reductions,
and faster-pair counts. Tests and CI have no performance threshold.

Linux results are supplementary component measurements. Native macOS measurements
and the full application test graph are separate CI steps. Neither measurement
includes JSON encoding, disk writes, queue delay, UI latency, or playback FPS.

## Results: supplementary Linux study, 2026-10-28

[The portable job passed](https://github.com/Jagalite/illiquid/actions/runs/40636406756/job/122644272957)
on commit `8dd4945c4e89e3efb61124a2a9c4f883f0ec80ab`. The host was a
GitHub `ubuntu-24.04` x86_64 runner, Linux 6.17.0-1022-azure, glibc 2.39,
using Swift 6.4 (`swift-6.4-RELEASE`). Native macOS execution was still queued
when these results were recorded. These are elapsed wall-time measurements,
not CPU-time measurements or a target-platform speed claim.

Both variants passed **20 component tests in four suites** in both debug and
release: six XCTest methods and fourteen Swift Testing tests per configuration.
The identity matrix independently exercises 11 query identities × 11 item
identities × six hints (726 combinations), including raw decoded URLs.

All **368 measured observations** (23 workloads × eight pairs × two variants)
and **46 calibration observations** are retained. Warmup record fingerprints
matched throughout each workload, every timed checksum passed, and an independent
post-run audit recomputed all summary statistics, paired ordering, iteration
counts, and exact UInt64 checksums. This audits one campaign; it is not a second
performance replication.

### Matching indices

Each absolute column is the median elapsed time per complete record. Percentage
reductions are the medians of within-pair ratios, so they need not equal the
percentage calculated from the two displayed medians.

| Workload | Normalized scan from #124 | Verified index | Paired reduction | Faster pairs |
|---|---:|---:|---:|---:|
| 32, matching middle index | 0.177 ms | 0.123 ms | 30.5% | 8/8 |
| 32, matching last index | 0.229 ms | 0.122 ms | 46.6% | 8/8 |
| 1,000, matching middle index | 5.412 ms | 3.674 ms | 32.2% | 8/8 |
| 1,000, matching last index | 7.172 ms | 3.701 ms | 48.6% | 8/8 |
| 10,000, matching last index | 73.337 ms | 37.692 ms | 48.6% | 8/8 |
| 1,000, Unicode paths / last index | 10.197 ms | 5.808 ms | 43.0% | 8/8 |
| 1,000 unique + 250 duplicates / matching index | 8.037 ms | 4.623 ms | 42.5% | 8/8 |

For the 1,000-item last-hit case, baseline observations ranged from 7.053–7.390 ms
per call, versus 3.677–3.797 ms with the index shortcut. At 10,000 items, the
ranges were 72.588–74.709 ms and 37.360–38.540 ms respectively. All seven matching
middle/late-index workloads improved in every retained pair.

### Controls and costs

| Workload | Normalized scan from #124 | Verified index | Paired reduction |
|---|---:|---:|---:|
| 1,000, first hit | 3.680 ms | 3.692 ms | -0.4% |
| 1,000, absent hint | 7.134 ms | 7.116 ms | 0.2% |
| 1,000, stale first hint / late hit | 7.148 ms | 7.121 ms | -0.1% |
| 1,000, missing source | 7.151 ms | 7.129 ms | -0.1% |
| 1,000, no folder | 3.670 ms | 3.648 ms | 0.3% |
| 10,000, no folder | 37.506 ms | 37.247 ms | 0.6% |
| 1,000, unsupported item URLs | 0.266 ms | 0.268 ms | -0.3% |

These small control differences do not establish a useful improvement. In
particular, skipping work for a missing folder is already implemented by #124.

Two costs are retained and disclosed:

- An empty playlist rose from 100.3 ns to 127.6 ns per record: **27.4 ns more**
  between medians, with a 26.7% median paired increase (8/8 pairs slower).
- A 32-item first hit with an incorrect last-item hint rose from 121.633 µs to
  125.100 µs: **3.466 µs more** between medians, with a 2.6% median paired increase
  (7/8 pairs slower). Checking a wrong hint can add one identity normalization
  before the original scan finds the source.

The bounds and identity check are required: an arbitrary stored index must
never establish membership by itself. The saved index is passed through unchanged.
The small empty-case overhead and wrong-hint cost are accepted in this candidate
in exchange for removing the membership scan on matching middle/late indices.

### Why the improvement is bounded

For a unique N-item playlist with a valid final-item hint, #124 normalizes one
source and N membership candidates, then the unchanged record constructor
normalizes N item identities during deduplication. The new membership check
normalizes only the source and the hinted item; deduplication still processes
N identities. That reduces identity work from approximately 2N + 1 to N + 2,
consistent with the roughly halved complete-construction time in the longer
late-hit workloads. Full construction remains O(N).

These synthetic warm-fixture results establish a component improvement on the
reported Linux host. They do not establish macOS timings, disk-save latency,
worker scheduling latency, memory savings, whole-player CPU, or playback FPS.

### Retained evidence

- [Manifest and source/binary hashes](evidence/linux/manifest.json)
- [All raw calibration and measured observations](evidence/linux/observations.jsonl)
- [All 23 workload summaries](evidence/linux/summary.json)
- [Independent arithmetic and integrity audit](evidence/linux/audit.json)
- [Test receipts and run identity](evidence/linux/qualification.json)

The retained JSON payloads were extracted from the successful job's log.
Observation lines preserve their original integer tokens, including 64-bit
checksums. The Actions artifact additionally holds the copied sources and full
command logs. The immutable measured commit supplies all implementation, driver,
test, and harness inputs.
