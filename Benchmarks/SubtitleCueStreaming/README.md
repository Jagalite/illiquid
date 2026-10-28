# Subtitle cue streaming

This experiment measures full SRT and WebVTT conversion to ASS. The candidate
streams the lines of each cue and appends escaped payloads directly to the final
output. It removes the per-cue line array, escaped-string array, joined payload,
and interpolated full Dialogue temporary. Newline normalization, block boundaries,
timestamp parsing, escaping, and the emitted format retain their existing rules.

## Reproduce

On macOS with Swift 6.1 or newer:

    python3 Benchmarks/SubtitleCueStreaming/run.py \
      --pairs 8 --target-ms 150 --output /tmp/subtitle-cue-streaming

Use a new output directory each time. The runner checks for Kyoto and explains
direct compilation when the shared queue is unavailable. When Kyoto is available,
submit the whole serial runner through that queue as described by its diagnostic.
The benchmark uses only the real Foundation converter; it does not need FFmpeg,
libass, a media fixture, or the player UI.

## Qualification

The baseline is commit ea2ff568237e2667f7b1aeee67b11a44ebe95b72. The runner
retrieves its complete converter from Git and compiles baseline and candidate
production sources with the same driver, in debug and optimized release modes.
All four builds must emit identical complete ASS outputs and typed errors over
the differential corpus. The existing converter and escaping test suites, plus
the cue streaming regressions, run against both variants in debug and release.

Timing uses eight balanced AB/BA pairs in fresh processes. Each variant is
independently calibrated to at least 150 ms of CPU and wall time; every final
sample must exceed 60 ms. Times are normalized per complete conversion, and
fixture/output receipts and consumed checksums must match. The workloads cover
ordinary SRT and WebVTT cues, multiline cues, dense line counts, a long single
line, and invalid preambles. Input construction and warmup are outside timing.

Dedicated fresh-process runs measure peak resident memory for dense and
long-line inputs. These are whole-process high-water marks, not allocation
counts or retained-memory claims. Raw measurements, compiler and machine
information, source and binary hashes, exact source snapshots, test logs, and
full correctness traces are retained in the CI artifact.

Results will be recorded after native qualification. These component
measurements do not establish playback frame-rate or end-to-end file-open gains.
