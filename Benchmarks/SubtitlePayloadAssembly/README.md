# Subtitle payload assembly research

## Candidate

The external SRT/WebVTT converter currently maps every accepted cue's payload
lines to escaped strings, joins them into a second string, and interpolates the
joined payload into the final ASS output. The candidate appends the existing
escaped lines directly to that final output, with the same literal `\\N`
separator between lines.

This removes the per-cue escaped-line array and joined-payload temporary. It
does not change block parsing, timestamps, cue admission, escaping, or newline
normalization. Empty payloads, empty final lines, and Unicode matching must
retain their exact output bytes. Any benefit must be established by measuring
complete conversions; removing an intermediate allocation alone is not a
player-wide performance result.

## Baseline and protocol

The baseline is the exact converter from
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`, after the earlier block-traversal
and escaping improvements. Its Git blob and SHA-256 are recorded in
[baseline/manifest.json](baseline/manifest.json). This isolates payload
assembly from the timestamp-parsing and newline experiments on other branches.

The small `run.py` entry point reuses
`Benchmarks/ExternalSubtitleConversion/run.py` without changing that
experiment's historical defaults. Both variants are built as separate
optimized production modules, then linked to the same driver. The runner
checks complete output UTF-8 bytes and exact errors before timing, validates
result receipts, retains source/compiler/binary hashes and raw observations,
and alternates fresh-process AB/BA pairs. No timing outliers are discarded.

The driver retains the existing converter corpus and adds single-line cues
and bounded 32/256-line payload stress cases. The full differential corpus
contains 1,722 cases; 60 workloads are available for timing. Ordinary fixtures
cover SRT/WebVTT, plain text, multilingual text, literal ASS metacharacters,
CRLF/CR, BOM, empty inputs, and invalid inputs.

Input construction, full-output verification, and warmup are outside the
timed region. Parsing, escaping, output assembly, result consumption, and
result destruction are timed together. These are warm component timings;
they exclude file decoding/I/O, libass rendering, and live player interaction.

## Reproduce

Use Swift 6.1 or later. Follow the repository's AGENTS.md build coordination:
use Kyoto when available; otherwise explain the absence and serialize builds.

```sh
bash Scripts/test-external-subtitle-regressions.sh -c debug --jobs 2 -Xswiftc -warnings-as-errors
bash Scripts/test-external-subtitle-regressions.sh -c release --jobs 2 -Xswiftc -warnings-as-errors

python3 Benchmarks/SubtitlePayloadAssembly/run.py benchmark \
  --rounds 8 --target-ms 150 \
  --output /tmp/illiquid-subtitle-payload-results
```

The output directory must be new or empty. Repeat `--case NAME` to select a
bounded subset; omitting it measures all 60 workloads. The focused workflow
runs the same new and existing tests against both production variants in
debug and release, and verifies every differential fixture before timing.

New regression cases independently specify complete expected ASS bytes for
empty and whitespace cues around rejected cues, literal versus inserted
line-break escapes, combining marks, trailing LF, and up to 4,096 payload lines.

## Status

Implementation and research fixtures are prepared. Performance and test
results are not yet qualified. The initial local environment ran out of shared
disk space before a Swift toolchain could be installed; these setup failures
are not test or benchmark results. Do not infer a speedup or a measured peak
memory reduction from this candidate until a completed evidence cohort is
recorded here.
