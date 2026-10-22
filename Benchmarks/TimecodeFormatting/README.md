# Playback timecode formatting

This experiment measures `TimecodeFormatter.string(from:)`, the formatter used
by the playback timeline, hover and thumbnail previews, accessibility text, and
the playback inspector. The production change is confined to that enum in
`Sources/IlliquidApp/UI/PlaybackControlBar.swift`.

## Hypothesis and change

The original implementation calls Foundation's general-purpose
`String(format:)` for every label. Minutes and seconds each have only 60 possible
two-digit representations. The candidate shares an immutable table of those
representations and uses ordinary interpolation for the hour field.

The initial table is created lazily. There is no mutable last-value cache or
per-window state. Negative and nonfinite intervals still produce `0:00`; zero
and positive intervals below one second still produce `00:00`. Rounding down,
padding, and hour widths remain unchanged. A rare fallback retains the original
`%d` behavior for hour counts above `Int32.max`. The existing `Double`-to-`Int`
input domain is unchanged.

## Scope

The standard timeline refresh policy updates every 200 ms while playing and
observable, normally formatting elapsed and total/remaining labels each time.
The same formatter also runs during user interaction and SwiftUI updates. This
is a small UI component cost; the experiment does not measure video decoding,
rendering, whole-player CPU, frame rate, energy, or end-to-end input latency.

Steady-state measurements warm the shared component table before timing.
They therefore exclude its one-time initialization cost. No allocation-count
claim is made. Each measured operation includes formatting and consuming the
complete result in a UTF-8 checksum; bounded autorelease-pool cleanup is also
inside the timed interval. The reported cost is for that workload, not an
isolated formatter instruction count or a real text-view update.

## Reproduce on macOS

Use the repository's pinned Xcode configuration, or record the compiler and SDK
when testing another environment:

```bash
export DEVELOPER_DIR=/Applications/Xcode_26.6.app/Contents/Developer
python3 Benchmarks/TimecodeFormatting/run.py \
  --output /tmp/illiquid-timecode-results --pairs 10 --target-ms 250
```

The output directory must be new or empty. The benchmark needs Foundation and
Swift, but does not need the app's FFmpeg or subtitle dependencies. It reads the
baseline revision from Git, so that revision must be available locally.

The companion native app qualification builds the real app dependency graph
with the reviewed native SDK and runs:

```bash
swift test --force-resolved-versions -c release --jobs 2 --no-parallel \
  --filter 'TimecodeFormatterTests|UXVerificationProbeTests'
```

The new five-test suite checks explicit expected strings, invalid and signed-zero
inputs, all 3,600 minute/second combinations at nine hour counts, adjacent
floating-point values at boundaries, and large representable intervals. The
reference in those differential tests retains the original Foundation call.

## Measurement method

Baseline: `7f9ba073394b77a908e0589447c6edc8d10b832c`.

The runner extracts the complete production enum from each revision and records
source and binary hashes. Debug and optimized builds verify exact output against
the baseline and independent golden strings before timing. The optimized
executables use identical runtime inputs, consume their output, and alternate
baseline/candidate process order across ten pairs. Calibration targets at least
250 ms per sample. Raw wall-time and process-CPU observations accompany the
summary so that variation can be inspected.

Each workload cycles through 4,096 runtime inputs:

| Workload | Input pattern |
| --- | --- |
| `continuous_short` | A position advancing from 0 to 819 seconds in 200 ms steps |
| `long_movie` | The same progression beginning at two hours |
| `scrubbing` | Deterministic millisecond positions spread across a 24-hour interval |
| `repeated_display` | Fractional positions from 42 to 42.9 seconds, all displaying `00:42` |

Each process warms 8,192 calls before measurement. Calibration uses the faster
variant with a 1.5x duration margin, then gives both variants the same iteration
count. The recorded measurements include ten alternating process pairs for each
workload, totaling 80 timed observations. The results below describe this one
native CI host; other hardware and OS/compiler versions were not measured.

The GitHub workflow `.github/workflows/timecode-formatting.yml` runs the isolated
native measurement and the native app tests as separate jobs. Test failures
propagate through the log-capture pipeline.

## Native app validation

The candidate commit `c3e68c2fa78e042e9d72050922cf66e9af6cd4c3` passed the
native release app build and all **12 selected tests in two suites**: five new
formatter tests and seven existing UX verification probes. The release build
took 493.56 seconds; Swift Testing reported 0.542 seconds for the selected tests.
These are targeted tests, not a claim that the entire repository suite ran.

- [Native app job](https://github.com/Jagalite/illiquid/actions/runs/39847090191/job/120063112723)
- [Test summary](evidence/macos-arm64/app-test-summary.log)
- [Test receipt](evidence/macos-arm64/app-test-receipt.json), including the full
  job-log hash and artifact identifier

## Timing results

The native run on **2026-10-22** completed successfully on an **Apple M1
(Virtual), arm64**, with three logical CPUs, macOS **26.6.2**, Apple Swift
**6.3.3**, and macOS SDK **26.5**. The working tree was clean. The measured
candidate was `c3e68c2fa78e042e9d72050922cf66e9af6cd4c3`; subsequent result-documentation
changes do not alter the production source, harness, or runner.

The optimized formatter workload improved across all four input patterns:

| Workload | Baseline wall ns/op | Candidate wall ns/op | Wall reduction | Baseline CPU ns/op | Candidate CPU ns/op | CPU reduction |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Short playback | 1,803.7 | 36.8 | 97.96% | 1,768.7 | 36.4 | 97.94% |
| Two-hour movie | 2,017.0 | 59.4 | 97.05% | 2,005.7 | 59.4 | 97.04% |
| Scrubbing over 24 hours | 2,175.3 | 66.5 | 96.94% | 2,171.0 | 66.4 | 96.94% |
| Repeated displayed second | 1,585.4 | 34.7 | 97.81% | 1,572.1 | 34.6 | 97.80% |

Values are medians of ten observations per variant, per workload. Reductions
use the ratio of those medians. All **40 paired comparisons** improved in both
metrics: paired wall-time reductions ranged from **96.26% to 98.45%**, and
paired CPU-time reductions ranged from **96.26% to 98.27%**. Every one of the
**80 timed observations** exceeded the 250 ms target; the shortest was
**291.0 ms**. No observations were discarded. Individual samples, ranges,
and paired reductions are retained below.

Correctness checks also passed:

- Exact output agreement for **87,860 input rows per binary** across baseline
  and candidate in both debug and optimized configurations, including every
  whole second from zero through 24 hours, fractional boundaries, invalid inputs,
  signed zero, and large representable intervals.
- **21 independent golden cases per binary** in addition to differential parity.
- Matching output checksums, warmup checksums, final strings, and iteration counts
  for every timed old/new pair.
- The native release app build and **12 selected regression tests** described above.

The change saves roughly **1.6–2.1 microseconds per operation** in these warmed
workloads. This is sufficient evidence for the small formatter change, while
its absolute impact on ordinary timeline refreshes is modest. These results do
not establish a whole-player CPU, frame-rate, energy, or visible UI-latency gain.
Initial table construction and allocation counts were not measured.

## Retained evidence

- [Successful native run](https://github.com/Jagalite/illiquid/actions/runs/39847090191)
  and [component job](https://github.com/Jagalite/illiquid/actions/runs/39847090191/job/120063113270)
- [Run receipt](evidence/macos-arm64/run-receipt.json): artifact identity and hash,
  log hash, and hashes for the compact evidence files
- [Environment](evidence/macos-arm64/environment.json) and
  [source/binary receipts](evidence/macos-arm64/source-receipts.json)
- [Exact-output parity](evidence/macos-arm64/parity.json) and
  [completion status](evidence/macos-arm64/completion.json)
- [Raw observations](evidence/macos-arm64/measurements.jsonl),
  [calibration](evidence/macos-arm64/calibration.json), and
  [statistical summary](evidence/macos-arm64/summary.json)
- [Executed commands](evidence/macos-arm64/commands.json)

The run's `timecode-formatting-macos` artifact also contains all four complete
verification traces, extracted source snapshots, and compiled binaries. That
artifact expires after 14 days; the compact evidence above remains in Git and
the committed runner regenerates the full output. The app test summary and
receipt are linked in the native validation section.
