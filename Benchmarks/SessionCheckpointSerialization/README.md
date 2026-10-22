# Session checkpoint serialization

## Question and change

`AtomicPlaybackSessionStore.save` encoded every crash-recovery checkpoint with
`JSONEncoder.OutputFormatting.sortedKeys`. That sorts object keys throughout the
document, including each playlist item. Restoration reads keyed values through
`JSONDecoder`; the session format has no canonical-byte or key-order contract.

The candidate removes that formatting option. It retains the existing schema,
encoder strategies, lock, directory creation, error propagation, and atomic file
replacement. Ordered playlist items, subtitle URLs, and shuffle-restoration IDs
remain arrays with their original order.

This path runs on the coalescing persistence writer's utility queue. Playback
position changes request a checkpoint after a ten-second position delta; pause,
source, and playlist changes can also request one. The experiment measures
background session-store work. Checkpoint preparation, queue scheduling, decoder
playback, UI responsiveness, power consumption, and complete shutdown latency
are outside the measurements.

## Reproduce

From the repository root on macOS 26 with the repository's Swift toolchain:

```sh
python3 Benchmarks/SessionCheckpointSerialization/run.py \
  --pairs 8 --target-ms 80 --output /tmp/illiquid-session-serialization
```

The output directory must be new or empty. The runner compares the working tree
with pinned baseline `7f9ba073394b77a908e0589447c6edc8d10b832c`; that commit must be
available locally. `--tests-only` runs compilation and compatibility checks.

The benchmark stages the actual Foundation-only source dependency graph into a
temporary Swift package. Only `PlaybackSessionStore.swift` may differ between
the baseline and candidate. On macOS it includes the real lifecycle-signpost
source. Linux staging substitutes a disabled lifecycle gate for the unavailable
Apple logging framework; persistence and model implementations remain intact.

## Method

Eight fixtures cover an empty remote-stream session; a one-item local playlist;
and playlists of 25, 250, and 2,500 items, each with plain and richer variants.
Richer variants have two external subtitles per item, dates, reversed playback
order, and saved shuffle-restoration IDs. Paths contain spaces, Unicode, and
percent signs. Inputs are synthetic and are prepared before timing.

Two measurements use optimized Swift builds:

- `save` calls the real `AtomicPlaybackSessionStore.save`, including its lock,
  directory check, encoding, and atomic replacement of the same temporary file.
- `encode` isolates the encoder statements mechanically extracted from each
  production implementation. The runner verifies this probe's complete JSON
  against the real saved file.

Each process performs three warm-up operations. A baseline pilot chooses the
iteration count, shared by both variants, targeting the requested sample length.
Eight process pairs alternate baseline/candidate and candidate/baseline order.
Position and timestamp change on every iteration. Wall and process CPU clocks
stop before output inspection. All samples are retained, including slower ones.
Reported save times therefore describe warmed repeated writes on the runner's
temporary filesystem, rather than a cold volume or network-mounted directory.
They do not establish storage flush or power-loss durability.

## Compatibility checks

Before measurement, both implementations round-trip every fixture through the
production store and extracted encoder. The runner compares complete parsed JSON
values between implementations, including all array ordering. Each timed process
also decodes and compares its final complete record outside the timed section.

The candidate runs `PlaybackSessionStoreTests` in debug and release. Coverage
includes the existing schema-one/session round trips, rewriting sorted historical
JSON while preserving all local/remote state, and an encoding failure that leaves
the previous checkpoint's bytes readable and unchanged.

## Evidence

The `Session checkpoint serialization` workflow runs this experiment on a native
macOS runner. Its artifact contains compiler and host information, source and
binary hashes, generated encoder probes, command/test logs, complete-state
comparison receipts, calibration data, every measurement, and summaries.

## Native result: inconclusive; no PR proposed

The first native run passed compatibility checks but did **not** establish a
consistent improvement in complete saves. The candidate remains a research
branch. A concurrent branch, `perf/session-checkpoint-json-20261022`, was also
found pursuing the same production change; no duplicate optimization PR is
proposed from this investigation.

[GitHub Actions run 39844606558](https://github.com/Jagalite/illiquid/actions/runs/39844606558)
measured candidate `1e0136c34e52940d49cfbba109bc9c5b35e9f771` on macOS 26.6.2,
Apple M1 (Virtual), three logical CPUs, Apple Swift 6.3.3, using eight alternating
process pairs and an 80 ms calibration target. These are exploratory shared-runner
measurements. Variability is substantial: several paired changes exceed 100%.
The reported changes below are ratios of medians, with every raw pair retained.

| Playlist items | Fixture | Baseline save ms | Candidate save ms | Wall change | CPU change |
|---|---|---:|---:|---:|---:|
| 0 | Plain | 1.000 | 1.086 | +8.57% | +6.83% |
| 1 | Plain | 0.946 | 0.898 | -5.07% | +8.02% |
| 25 | Plain | 1.027 | 1.014 | -1.20% | +4.19% |
| 25 | Subtitles, dates, shuffle IDs | 1.003 | 1.110 | +10.67% | +11.86% |
| 250 | Plain | 2.568 | 2.246 | -12.54% | -1.34% |
| 250 | Subtitles, dates, shuffle IDs | 4.030 | 4.431 | +9.96% | -8.73% |
| 2,500 | Plain | 12.535 | 12.203 | -2.65% | +2.10% |
| 2,500 | Subtitles, dates, shuffle IDs | 28.269 | 26.319 | -6.90% | -7.56% |

Encoding-only medians were also mixed, spanning 16.94% faster to 11.78% slower in
wall time. The 2,500-item rich save improved by 6.90% wall and 7.56% process CPU,
but smaller controls and the 25-item rich fixture did not support a broad claim.
Removing source-level work alone is insufficient evidence of a user benefit.
A future claim would need longer, less variable samples and the complete save
path evaluated independently of the encoder-only result.

Both implementations passed eight complete-JSON comparisons. Six session-store
tests (including one two-case parameterization) passed in each of debug and
release. All 256 timed processes also verified their final complete records.
The compact native receipts and all raw measurements are in
[`evidence/macos-arm64`](evidence/macos-arm64); complete compiler command logs
remain in the linked workflow artifact.

