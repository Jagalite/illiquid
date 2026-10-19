# External SRT/WebVTT conversion performance

Date: October 17, 2026. Repository: `Jagalite/illiquid`.
Baseline: `68274d1b09dcc866296321a5a8858efc297c4f19`.

## Scope and finding

This investigation targets external subtitle preparation through
[`ExternalTextSubtitleConverter`](../Sources/IlliquidNativePlayback/Subtitles/ExternalTextSubtitleConverter.swift).
[`SubtitlePipeline.prepareExternalData`](../Sources/IlliquidNativePlayback/Subtitles/SubtitlePipeline.swift)
decodes an external SRT/WebVTT file, converts it to ASS, checks the converted
UTF-8 size, and then passes the data onward for installation. The caller admits
bounded files (32 MiB by default). Conversion is loading/track-change work;
it is not part of every playback frame.

The baseline performs three Foundation replacements on every payload line,
even when the line has no backslash or brace. The change classifies the line
once, returns unchanged payloads directly, and builds escaped ASCII payloads
in a byte buffer sized to the exact result. If the scan finds both non-ASCII
text and an escape target, it stops classification immediately and uses the
original Foundation operations.

The implementation changes one production helper and its call site. The
benchmark measures the complete converter rather than timing just the helper.
The tables below describe an optimized Linux component experiment; native
Foundation results belong to the PR's macOS CI receipts.

## Compatibility discovery

A blind UTF-8 replacement would change existing behavior. A baseline probe
showed that Foundation leaves a backslash/brace followed by certain combining
marks, variation selectors, or combining grapheme joiners untouched. A brace
followed by a zero-width joiner was escaped. The regression suite records these
boundaries, using byte comparisons so canonical String equality cannot hide
changes.

Accordingly, any non-ASCII line containing an escape target retains all three
original Foundation replacements, in their original order. This preserves
platform-specific Foundation behavior without implementing a second Unicode
search engine. Foundation's treatment of composed sequences is described in
[Apple's string search guide](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/Strings/Articles/SearchingStrings.html).

ASCII escape output has length `n + k`, where `n` is the payload byte count
and `k` is the count of the three target bytes. Prefixes are added only to
original bytes. The existing joined `\N` separators are inserted afterward
and never re-escaped. The parser, timestamps, malformed-cue handling, encoding
policy, and caller's size checks retain their existing behavior.


## Final measurements

Environment: Linux x86-64, Intel Xeon Platinum 8573C, Swift 6.2.1, Swift 6
language mode. This is a shared host with no CPU pinning, frequency lock, thermal
control, or quiescence. Both implementations used identical compiler flags and
fresh processes. The source and binary hashes are in the
[final manifest](../Benchmarks/ExternalSubtitleConversion/evidence/linux/final/manifest.json).

All 24 ordinary LF workloads (both formats, four sizes, three payload types)
have lower median paired conversion time. Ordinary 2,000-cue SRT workloads
improve 31.2–51.8%, and their WebVTT counterparts improve 26.4–43.6%.
These percentages are medians of the ten candidate/baseline pair ratios, so
may differ from the ratio of the two separately reported medians.

| Workload | Baseline median (ms) | Candidate median (ms) | Median paired change |
| --- | ---: | ---: | ---: |
| `srt-2000-plain` | 65.3180 | 46.2121 | -31.2% |
| `srt-2000-multilingual` | 101.8296 | 57.6147 | -40.3% |
| `srt-2000-escaped` | 99.7352 | 45.9099 | -51.8% |
| `vtt-2000-plain` | 82.3033 | 62.2264 | -26.4% |
| `vtt-2000-multilingual` | 109.4346 | 72.1031 | -34.5% |
| `vtt-2000-escaped` | 110.7661 | 61.3293 | -43.6% |
| `srt-10000-plain` | 327.9103 | 224.1395 | -32.5% |
| `vtt-10000-plain` | 428.2440 | 299.8968 | -27.5% |

### Controls and tradeoffs

Unicode lines with actual escape targets retain Foundation processing. The
2,000-cue Unicode-escape controls show **+4.1% SRT and +2.7% WebVTT median paired
cost**; combining-mark fallback controls show -2.3% and -0.1%. This path is kept
for compatibility, with a small classification cost. The result is not a
universal speedup for every valid payload.

Error-only paths do not reach the new helper, yet this cohort shows larger
relative changes in very short timings: empty WebVTT is 0.0031 → 0.0039 ms;
invalid-only SRT is 0.0194 → 0.0277 ms. Missing-signature WebVTT is
0.0040 → 0.0042 ms. These are observed regressions of a few microseconds in this cohort. Their
cause is not isolated by this experiment; no error-path speedup is claimed.

Individual pair ratios are noisy, and some ordinary-input pairs reverse direction.
For example, the 2,000-cue plain SRT ratio spans 0.372–1.248, while the ASCII
escape-heavy SRT ratio is 0.275–0.505 (every pair faster). The full
[summary](../Benchmarks/ExternalSubtitleConversion/evidence/linux/final/summary.json)
retains every ratio, per-variant min/max, and CPU timing. Medians are descriptive
component results, not a confidence interval or guaranteed Mac latency.

No allocation, peak-memory, battery, rendering, file-I/O, or end-to-end player
speedup claim is made. The experiment isolates real conversion work which the
caller performs during external subtitle loading.

## Verification and measurement integrity

- The existing 15 parser/timestamp tests plus eight independently stated escaping
  tests pass for baseline and candidate, in both debug and release, with warnings
  treated as errors: **23 test functions in two suites for each run**.
- The complete converters produce matching UTF-8 bytes and typed errors on
  **1,698 cases**, including malformed inputs, combining sequences, compatibility
  punctuation, NUL, and exhaustive short sequences over a
  nine-atom alphabet. Long-payload behavior is also covered by the unit suite.
- The final timing cohort has **720 observations: 36 workloads × 10 pairs × two
  implementations**. An independent audit confirms five AB and five BA pairs
  for every workload, matching operation counts and complete output receipts.
- The driver measures full conversion and result-byte-count consumption. Fixture
  construction, hashing, full-byte verification, and receipt serialization stay
  outside the interval. No platform parser stubs are used.
- An independent code review found no correctness blocker in the final helper.
  Full app/media playback was not executed on this Linux host.

### Saved-record recovery

The benchmark process reported a complete cohort and generated its summary,
but a subsequent audit of the saved JSONL found 719 rows: the final baseline
record was missing. The incomplete file and its original summary are archived
under [recovery](../Benchmarks/ExternalSubtitleConversion/evidence/linux/final/recovery/receipt.json).
Both members of that final one-cue SRT pair were rerun with the same binaries and
operation count; the orphaned candidate observation was replaced as a pair,
not removed for its timing. The final summary was regenerated from the resulting
720 real observations and independently revalidated. The recovered pair is the
only replacement; the other 359 pairs are unchanged. A compressed complete
checkpoint was also compared with the final raw records before copying evidence.

The earlier two-pair exploratory cohort is retained separately with its exact
candidate source (before the early classification exit). It supplies no final
headline values. No trial substituted a byte-only Unicode implementation into
production: the baseline probe identified that compatibility failure first.

## Native qualification and reproduction

See the [benchmark README](../Benchmarks/ExternalSubtitleConversion/README.md)
for exact commands and detailed timing boundaries. The frozen baseline verifies
its original Git blob and SHA-256 before each build. Source/driver snapshots,
compiler flags, binary hashes, raw timings, full differential byte receipts,
process commands, and passing test logs are checked in under
[`evidence/linux`](../Benchmarks/ExternalSubtitleConversion/evidence/linux).

The new macOS workflow runs debug/release tests and the same complete paired
benchmark against native Foundation, uploading `external-subtitle-conversion-native`.
Its result and the PR's existing full native application suite are separate
qualification evidence; they are not inferred from these Linux measurements.
Consult the pull request checks for current native status and results.

## Complete timing matrix

Negative paired change means less conversion time. Small controls are printed
in milliseconds here; their exact nanoseconds remain in the raw JSON.

| Workload | Baseline median (ms) | Candidate median (ms) | Median paired change |
| --- | ---: | ---: | ---: |
| `srt-1-plain` | 0.0341 | 0.0240 | -29.5% |
| `srt-100-plain` | 3.2786 | 2.1948 | -35.0% |
| `srt-2000-plain` | 65.3180 | 46.2121 | -31.2% |
| `srt-10000-plain` | 327.9103 | 224.1395 | -32.5% |
| `srt-1-multilingual` | 0.0477 | 0.0303 | -35.4% |
| `srt-100-multilingual` | 4.5175 | 2.8059 | -38.1% |
| `srt-2000-multilingual` | 101.8296 | 57.6147 | -40.3% |
| `srt-10000-multilingual` | 460.2847 | 286.8967 | -37.1% |
| `srt-1-escaped` | 0.0489 | 0.0247 | -49.8% |
| `srt-100-escaped` | 4.7938 | 2.2947 | -52.2% |
| `srt-2000-escaped` | 99.7352 | 45.9099 | -51.8% |
| `srt-10000-escaped` | 481.2847 | 239.8007 | -50.5% |
| `vtt-1-plain` | 0.0434 | 0.0327 | -24.8% |
| `vtt-100-plain` | 3.9300 | 3.1687 | -24.8% |
| `vtt-2000-plain` | 82.3033 | 62.2264 | -26.4% |
| `vtt-10000-plain` | 428.2440 | 299.8968 | -27.5% |
| `vtt-1-multilingual` | 0.0585 | 0.0464 | -28.1% |
| `vtt-100-multilingual` | 5.2959 | 3.7953 | -31.2% |
| `vtt-2000-multilingual` | 109.4346 | 72.1031 | -34.5% |
| `vtt-10000-multilingual` | 591.1281 | 359.4968 | -32.6% |
| `vtt-1-escaped` | 0.0587 | 0.0334 | -43.5% |
| `vtt-100-escaped` | 5.9373 | 2.9785 | -47.3% |
| `vtt-2000-escaped` | 110.7661 | 61.3293 | -43.6% |
| `vtt-10000-escaped` | 545.8613 | 349.1303 | -42.3% |
| `srt-100-plain-crlf` | 3.5761 | 2.5567 | -28.7% |
| `vtt-100-multilingual-crlf` | 5.7207 | 5.4635 | -23.3% |
| `srt-100-escaped-cr` | 4.9113 | 2.5817 | -47.1% |
| `vtt-100-escaped-bom` | 5.7071 | 3.2489 | -41.1% |
| `srt-empty` | 0.0010 | 0.0010 | -3.1% |
| `vtt-empty` | 0.0031 | 0.0039 | +31.1% |
| `vtt-missing-signature` | 0.0040 | 0.0042 | +2.1% |
| `srt-no-valid-cues` | 0.0194 | 0.0277 | +42.8% |
| `srt-2000-unicode-escaped` | 98.9493 | 107.7299 | +4.1% |
| `srt-2000-combining-escaped` | 58.4376 | 56.9603 | -2.3% |
| `vtt-2000-unicode-escaped` | 112.0510 | 114.0077 | +2.7% |
| `vtt-2000-combining-escaped` | 74.6907 | 75.4277 | -0.1% |
