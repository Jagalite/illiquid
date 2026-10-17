# External subtitle conversion benchmark

This benchmark compares the complete `ExternalTextSubtitleConverter.convert()`
operation using a frozen source file and the current production source. Both are
compiled unchanged with the same driver into separate Swift release executables.
There are no mocks, import rewrites, package dependencies, or runtime downloads.

The baseline is pinned to the revision, Git blob, and SHA-256 in
`baseline/manifest.json`. The runner checks its hashes before compiling.

## Run

Use Python 3.10 or newer and a Swift 6.1 or newer toolchain with Foundation on
Linux or macOS:

```sh
python3 Benchmarks/ExternalSubtitleConversion/run.py \
  --output /tmp/external-subtitle-results \
  --samples 6
```

`--output` must be a new or empty directory. `--swiftc /path/to/swiftc` selects an
explicit toolchain; `SWIFTC` is also supported. `--cpu N` optionally pins timed
processes to an allowed Linux CPU. Use `--verify-only` for correctness without
timing, `--list-cases` to print workload definitions, or `--cases NAME,NAME` to
time a subset. Every timed run verifies the entire correctness corpus first.

## Workloads and equivalence

| Workloads | Shape |
| --- | --- |
| `srt-short-{1,1000,10000}` | Ordinary one- and two-line ASCII captions, LF |
| `vtt-short-{1,1000,10000}` | Ordinary captions with cue IDs/settings; 1,000-cue case uses CRLF |
| `srt-unicode-1000` | Multilingual, emoji, decomposed accents, paths and ASS literals, CR |
| `vtt-unicode-1000` | The same text profile in WebVTT, LF |
| `srt-long-128` | Approximately 8 KB per cue without ASS escapes |
| `srt-long-late-unicode-128` | The same long ASCII prefix with a final `é`, exercising late fallback |
| `vtt-escape-dense-1000` | Two lines per cue with many backslashes and braces |

The separate untimed comparison checks all 11 workloads and 400 additional
fixtures. These include LF/CRLF/CR, empty and trailing payload lines, Unicode
combining marks attached to ASS delimiters, variation selectors, controls,
WebVTT signature/metadata/comment rules, malformed and boundary timestamps, and
256 fixtures from a fixed generator. It compares complete successful UTF-8 output
bytes and explicit conversion-error labels. Swift `String` equality alone would
not establish byte identity for canonically equivalent Unicode text.

## Measurement and evidence

Each process constructs its selected input before warmup and both clocks. The
runner calibrates iteration counts from three warmed baseline conversions toward
`--target-ms` (200 ms by default), then uses the same counts for both variants.
Each sample gets a fresh process and two to ten warmup iterations. Samples
alternate baseline/candidate and candidate/baseline order, with an even sample
count and rotating workload order.

The timed loop includes full conversion, the returned String's lifetime, and a
small no-inline sink observing its UTF-8 count, first byte, and last byte. The
resulting sink is printed after timing and checked between variants. Complete
byte comparison and JSON serialization are outside the timer. Wall time uses
`DispatchTime.uptimeNanoseconds`; process CPU time uses
`clock_gettime(CLOCK_PROCESS_CPUTIME_ID)` over the same loop.

The output directory contains copied source/driver/runner files, source and
executable hashes, compiler target/version/flags, environment information,
commands, workload definitions, calibration, compressed complete verification
receipts, per-fixture input/output hashes, raw measurements, and median/min/max
summaries. Speedup is baseline median divided by candidate median; reduction is
one minus the reciprocal of that ratio. There is no timing pass/fail threshold.

A final summary is written only after atomic receipt finalization and read-back
checks confirm every expected sample identity and AB/BA order, raw command output,
and paired inputs/iteration counts/sinks. The summary includes receipt counts and
SHA-256 hashes so a saved cohort can be audited independently.

These synthetic measurements cover conversion after text decoding. They do not
measure file access, native rendering, playback, allocations, peak memory, or
process startup. Foundation implementations and system scheduling can affect
results, so report the measured platform and variability with any performance
claim.
