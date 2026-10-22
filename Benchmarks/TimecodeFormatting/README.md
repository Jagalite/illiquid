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
inputs, all 3,600 minute/second combinations at nine hour widths, adjacent
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

The GitHub workflow `.github/workflows/timecode-formatting.yml` runs the isolated
native measurement and the native app tests as separate jobs. Test failures
propagate through the log-capture pipeline.

## Results

Native results and their evidence will be recorded here after the experiment
completes. This document does not claim a speedup before that measurement.
