# External subtitle conversion peak memory

Date: October 23, 2026. Baseline: `af1c1add701e49b355448cf8983eaed1e7623108`.

## Scope and finding

[`SubtitlePipeline.prepareExternalData`](../Sources/IlliquidNativePlayback/Subtitles/SubtitlePipeline.swift)
admits external subtitle files up to 32 MiB, decodes SRT/WebVTT to a String,
converts that text to ASS, and checks the converted byte count before installation.
This is file-opening and subtitle-selection work. The earlier
[conversion study](EXTERNAL_SUBTITLE_CONVERSION_PERFORMANCE.md) optimized
payload escaping; it did not measure or remove whole-file temporary arrays.

The converter retained `normalized.components(separatedBy: "\n\n")`, an array
of every source block, while building another array of every converted event.
Joining the events then allocated the final output while the intermediate
storage could still be alive. Even an input with many empty blocks required a
large array of String values.

[`ExternalTextSubtitleConverter`](../Sources/IlliquidNativePlayback/Subtitles/ExternalTextSubtitleConverter.swift)
now visits blocks through a forward-only iterator. Each block is a Substring
sharing the normalized input's storage, and each accepted event is appended
directly to one output String. Temporary parsing and escaping storage is scoped
to the current block. The implementation still owns the decoded input and full
ASS output; it does not stream file I/O or change the renderer's ownership.

## Compatibility

The block delimiter remains a non-overlapping pair of LF bytes after the
existing CRLF/CR normalization. LF cannot occur within a multibyte UTF-8 scalar
and has no alternate canonical representation. The iterator advances after
both separator bytes and preserves empty blocks, a single trailing payload LF,
and WebVTT's unconditional first-block skip.

All existing timing selection, timestamp parsing, malformed-cue rejection,
NOTE/header handling, and payload escaping remain in place. In particular,
Unicode payloads containing ASS metacharacters still use the original
Foundation replacements, preserving their composed-sequence behavior.

Eight added regression functions check delimiter runs, trailing/leading empty
blocks, CRLF/CR, whitespace-only payload lines, non-LF Unicode separators,
WebVTT header boundaries, malformed first timing lines, multiple identifiers,
and exact Unicode/control bytes. Together with the existing tests, **33 test
functions in two suites pass for both baseline and candidate in debug and
release with warnings treated as errors**. The unchanged differential harness
also confirms **1,698 exact UTF-8 output/error matches** against its independently
frozen historical converter. Test logs, source hashes, and every differential
case's input/output hashes are retained under
[`evidence/linux`](../Benchmarks/ExternalSubtitleMemory/evidence/linux).

## Measurement method

The [memory harness](../Benchmarks/ExternalSubtitleMemory/README.md) freezes the
converter from current main, verifies its Git blob and SHA-256, and builds both
variants as separately optimized Swift modules with the same driver and flags.
Python creates fixture files before measurements. Each observation launches a
fresh process and performs exactly one conversion without a warm conversion.

`getrusage(RUSAGE_SELF)` captures peak RSS immediately after conversion, before
encoding or writing the output, hashing, or serializing results. The input and
result remain alive. Process CPU and monotonic elapsed time cover conversion;
peak RSS also includes Swift/Foundation startup, input loading, and allocator
behavior. Pre-conversion peak RSS is retained as a diagnostic and is not
subtracted to manufacture an allocation estimate.

The final Linux cohort uses six adjacent baseline/candidate pairs for each of
16 workloads, alternating AB and BA and reversing workload order: 192 fresh
processes. Every sample is retained. Each successful output fits the production
32 MiB bound and is compared byte-for-byte with its paired output. Typed errors,
byte counts, and output hashes are checked across the complete cohort.

Environment: Ubuntu 24.04, Linux x86-64, AMD EPYC 9V74, Swift 6.3.2, Swift 6
language mode, `-O -whole-module-optimization`. No other agent builds or
benchmarks run during this cohort. The host is shared, without CPU pinning,
frequency locking, or thermal control. Results describe this component and
environment; native Foundation and end-to-end playback require their own
measurements.

## Results

All **96 paired peak-RSS comparisons improve**; all 16 workloads have lower
median peak RSS. Ordinary 2,000-cue files save roughly 0.5–0.7 MiB in this
process. The 200,000-cue stress files save about 55.7 MiB (approximately 48%).
Long ASCII and Unicode payload cases save 37–41%.

| Workload | Input MiB | Baseline peak MiB | Candidate peak MiB | Median paired RSS change | Median paired wall change |
| --- | ---: | ---: | ---: | ---: | ---: |
| `srt-2000` | 0.10 | 17.49 | 16.83 | -3.8% | -12.3% |
| `srt-50000` | 2.70 | 41.28 | 27.34 | -33.7% | -7.8% |
| `srt-200000` | 11.08 | 116.08 | 60.41 | -48.0% | -8.1% |
| `srt-long-payload` | 15.73 | 103.62 | 65.26 | -37.0% | -31.9% |
| `srt-unicode-long-payload` | 15.71 | 117.00 | 69.72 | -40.4% | -5.8% |
| `srt-crlf` | 2.89 | 45.18 | 37.84 | -16.2% | -2.2% |
| `srt-malformed` | 2.22 | 24.03 | 18.68 | -22.3% | -14.7% |
| `srt-blank-heavy` | 2.00 | 34.65 | 18.54 | -46.5% | -65.7% |
| `vtt-2000` | 0.10 | 17.54 | 17.01 | -3.4% | -10.0% |
| `vtt-50000` | 2.70 | 41.36 | 27.34 | -34.0% | -8.3% |
| `vtt-200000` | 11.08 | 116.10 | 60.45 | -47.9% | -6.7% |
| `vtt-long-payload` | 15.73 | 103.66 | 65.19 | -37.1% | -31.6% |
| `vtt-unicode-long-payload` | 15.71 | 117.58 | 69.75 | -40.7% | -11.4% |
| `vtt-crlf` | 2.89 | 45.25 | 37.52 | -17.2% | -4.3% |
| `vtt-malformed` | 2.22 | 24.05 | 18.79 | -21.8% | -16.8% |
| `vtt-blank-heavy` | 2.00 | 34.76 | 18.54 | -46.6% | -66.5% |

Peak columns are separate variant medians. Percentages are medians of the six
paired changes and therefore need not equal the ratio of the displayed medians.
The [complete summary](../Benchmarks/ExternalSubtitleMemory/evidence/linux/final/summary.json)
includes ranges, every ratio/difference, CPU timing, and pre-conversion peaks.

Conversion time improves in 82 of 96 pairs and in every workload's median, but
individual regressions remain in the raw records. For example, one 2,000-cue
WebVTT pair is 51.4% slower and one 200,000-cue WebVTT pair is 13.2% slower.
No samples were removed. The timing observations are descriptive results on
a shared host, without a confidence interval or a guaranteed Mac latency gain.

The [independent audit](../Benchmarks/ExternalSubtitleMemory/evidence/linux/final/independent-audit.json)
checks all 192 observations, three AB and three BA pairs per workload, equal
output/error receipts, and exact agreement between the measured source/driver/runner
snapshots and the proposed files. Curated evidence retains every measurement and
process receipt, command/build logs, hashes, source snapshots, and test results.
Generated fixtures, full output files, and binaries are reproducible from the
harness and are excluded from the repository.

## Native qualification and reproduction

Run the production-source semantic checks with:

```sh
bash Scripts/test-external-subtitle-regressions.sh -c debug -Xswiftc -warnings-as-errors
bash Scripts/test-external-subtitle-regressions.sh -c release -Xswiftc -warnings-as-errors
python3 Benchmarks/ExternalSubtitleConversion/run.py verify \
  --output /tmp/external-subtitle-conversion-parity
python3 Benchmarks/ExternalSubtitleMemory/run.py benchmark \
  --rounds 6 --output /tmp/external-subtitle-memory
```

The existing macOS 26 workflow now also runs the memory harness with four
balanced pairs per case and preserves its receipts in
`external-subtitle-conversion-native`. It selects the Xcode compiler through
`xcrun --find swiftc`. Its existing debug/release tests and full conversion
parity/timing checks remain enabled.

Local validation does not execute the macOS application, libass rendering, or
file decoding. The change reduces converter working memory; it does not promise
the same reduction in the entire player's steady-state footprint. The final
ASS output, normalization, and a single unusually large cue can still require
substantial memory. Consult the PR checks for native status rather than
inferring native results from Linux measurements.
