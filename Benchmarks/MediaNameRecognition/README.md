# Filename metadata recognition experiment

Compare the actual Foundation-based `MediaNameRecognition.recognize(relativePath:)`
with the frozen source from main at
`68274d1b09dcc866296321a5a8858efc297c4f19`. The baseline source and its SHA-256
receipt are in `baseline/`; the candidate is read from the working tree.

```sh
python3 Benchmarks/MediaNameRecognition/run.py \
  --output /tmp/illiquid-name-recognition --rounds 6 --iterations 16

# Exact-output verification without the timing campaign:
python3 Benchmarks/MediaNameRecognition/run.py \
  --output /tmp/illiquid-name-recognition-check --verify-only

# Longer targeted follow-up; the complete equivalence corpus still runs first:
python3 Benchmarks/MediaNameRecognition/run.py \
  --output /tmp/illiquid-name-recognition-mixed \
  --workloads mixed-library --rounds 12 --iterations 128
```

Omitting `--workloads` times all eight cases. The option accepts one or more
space-separated case names in the desired order and rejects unknown, duplicate,
or empty names. It filters only the timing campaign after full equivalence;
the complete fixture catalog remains saved, and the manifest records the
requested names and the selected timed workloads. Keep targeted follow-ups
separate from earlier cohorts.

Use a new output directory for every run. The runner requires Python 3 and a
Swift 6 compiler available as `swiftc` or selected by `SWIFTC`. macOS builds
target macOS 26.0; Linux uses its real Foundation implementation. Results from
different platforms or toolchains are separate cohorts. The runner makes no
network requests and does not require the player's native dependency SDK.

## Correctness before timing

An optimized verifier compiles the candidate and a mechanically renamed baseline
recognizer together. It keeps a separately renamed frozen result type, so baseline
display formatting remains independent. The reviewed candidate type snapshot permits the
episode display formatting change only: its fields, other computed properties, and
all surrounding declaration text must still match exactly. Further type drift or a
mismatched baseline source hash requires review. The frozen source, reviewed type,
transformed oracle, and runner are included in the source receipts. The baseline
algorithm is otherwise copied verbatim.

Before any timing, it compares every stored field and the derived `seriesTitle`,
`displayName`, and `section`. String fields, optional strings, and string arrays
are compared as complete UTF-8 arrays, preserving differences that Swift's
canonically equivalent string equality would hide. The corpus includes 2,000
deterministically generated paths, curated movie/episode/extra/unknown cases,
valid and invalid dates, Unicode digits, composed/decomposed text, zero-width
characters, NUL, overlapping/unclosed tags, filename and ancestor identities,
tag-only folders, yearless show folders, and every timed filename. The complete
input list is saved as `fixtures.json`.

The small output checksum supplements those exact comparisons; it is not their
sole oracle. Each timing pair must also agree on operation counts, warmup receipt,
and a stable receipt consuming all result fields and derived display strings.

## Measurement scope

Each variant is compiled as its own shared module with identical
`-swift-version 6 -O -whole-module-optimization -warnings-as-errors` flags.
The timing harness is compiled separately without cross-module optimization.
Production code is not adapted or replaced by stubs.

Eight predefined workloads cover mixed libraries, named episodes, folder-derived
episodes, movies, dated episodes, plain unknown names, tagged/Unicode names,
and deliberately long-name stress. These are synthetic in-memory relative paths;
the long names can exceed real filesystem component limits. Their prevalence in
actual user libraries is unknown.

`--iterations` counts complete passes over one workload's 32–112 paths. The
default 16 therefore measures 512–1,792 recognitions per process. Two untimed
passes warm up the static regexes and Foundation before each observation.
Input construction and output-array reservation occur before the clock starts.
The interval includes recognition and appending every result to the reserved
array. The full-result receipt is calculated after the timer stops; all results
remain observable. This retention/append overhead is shared by both variants.

Every observation runs in a fresh process. Each workload has at least six pairs,
with equal baseline-first and candidate-first counts. All observations are kept,
including slower controls; there is no timing threshold or outlier removal.
The summary records each variant's minimum, median, and maximum nanoseconds per
name, all paired candidate/baseline ratios, and the median paired time reduction.
That paired percentage need not equal a ratio of the independently reported
medians. Min/max values are observed ranges, not confidence intervals.

This experiment measures complete filename recognition with warmed regular
expressions. It excludes directory enumeration, file I/O, metadata sidecars,
SwiftUI projection/rendering, decoding, playback, and first-use regex compilation.
It does not establish whole-player latency, CPU, memory, or energy improvements.

## Evidence

The output directory retains:

- `manifest.json`: platform/toolchain, command flags, source/runner/harness and
  executable/library hashes, parameters, and hashes of completed evidence.
- `sources/`: exact baseline, candidate, renamed oracle, harness, and runner.
- `fixtures.json` and `equivalence.json`: complete fixture paths and exact-output
  comparison receipt.
- `measurements.jsonl` and `summary.json`: every timed observation and recomputed
  summary, with balanced ordering and matching-result checks.
- `commands.jsonl` and `logs/`: every compiler/process command, exit status,
  stdout/stderr hashes, and original output.

Each timing record is flushed to disk. Before success, the saved JSONL is read
back and required to match the complete in-memory cohort, and source/binary
hashes are checked again. Failed runs retain their existing logs and are not
automatically pooled with later runs. Key evidence is also emitted between
`EVIDENCE_BEGIN` / `EVIDENCE_END` log markers; measurements are represented there
as one JSON array, which can be restored to JSONL without changing row contents.

## GitHub Actions

The media-name recognition workflow runs debug/release recognition tests,
related metadata integration tests, and full exact-output verification on
relevant pull requests. Manual workflow dispatch also runs the complete
eight-workload timing campaign. Timings are evidence rather than a pass/fail
threshold. The [research report](../../Documentation/MEDIA_NAME_RECOGNITION_PERFORMANCE.md)
records the original native cohorts, scope, and committed raw receipts.
