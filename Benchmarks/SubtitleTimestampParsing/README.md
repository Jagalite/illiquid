# External subtitle timestamp parsing

## Hypothesis and scope

The external SRT and WebVTT importer parses two timestamps per cue. The general
parser splits each timestamp into colon and fraction arrays, validates each
decimal component, and constructs the final millisecond/centisecond values.
Most authored cues use fixed-width ASCII timestamps, which can be validated
directly in one borrowed UTF-8 buffer.

The production change recognizes `HH:MM:SS,mmm` and `HH:MM:SS.mmm` for SRT,
and `HH:MM:SS.mmm` and `MM:SS.mmm` for WebVTT. Every byte is checked. It uses
the original parser whenever the shape, digits, field bounds, or contiguous
storage do not qualify. Existing whitespace/settings normalization, legacy SRT
fractions, large-hour bounds, cue ordering, escaping, and output construction
remain in their existing paths. Two-digit hours bound successful fast-path
arithmetic, including the rounding carry into hour 100.

This experiment measures **complete text-to-ASS conversion**, including parsing
all cues, escaping payloads, constructing results, and releasing each result.
It does not measure disk reads, text decoding, libass rendering, whole-player
CPU, playback throughput, battery use, or visible subtitle-loading latency.
The synthetic files cover several ordinary sizes and a 10,000-cue stress case.

Baseline: `ea2ff568237e2667f7b1aeee67b11a44ebe95b72` (current `main` when selected).
The exact complete converter is frozen in `baseline/`, with both its Git blob
identity and SHA-256 recorded. The candidate is the complete working-tree
production file. No other production source is substituted in this experiment.

## Reproduce

Python 3.9 or later and Swift 6.1 or later are required. The component needs
Foundation only; it does not resolve the native player SDKs. Follow `AGENTS.md`
and use Kyoto when available. Otherwise run in an isolated environment without
other builds or benchmarks:

```sh
python3 Benchmarks/SubtitleTimestampParsing/run.py benchmark \
  --output /tmp/subtitle-timestamp-results --run-tests \
  --rounds 10 --target-ms 250
```

The output directory must be new or empty. `--swiftc` selects a compiler.
`verify` replaces `benchmark` to run correctness checks without timings;
`summarize` recomputes statistics from an existing complete cohort. `--case`
can select individual cases for development, but the qualification uses the
entire predefined cohort.

The new workflow runs both native component qualification and a release build
of the complete application/test graph on `macos-26` using the repository's
pinned Xcode/native dependencies. The integration job executes the converter,
escaping, timestamp, and subtitle-file encoding/import suites through
`Scripts/tests/run-native-swift-tests.sh`, which requires a nonzero executed
test count. It does not launch a live player window.

## Measurement method

Each complete converter is compiled as a separate optimized Swift module, then
linked to the identical driver without cross-module optimization. Runtime fixture
selection and the module boundary prevent the driver from deleting or hoisting
conversion. Source, driver, compiler, module, library, and executable hashes
are retained in the manifest.

Input creation, a complete warm-up conversion, and full UTF-8 output validation
are outside timing. Every timed result contributes its byte length or exact
error token to an independently checked checksum; normal result destruction
is inside the loop. Each process verifies a complete result again after timing.
Both monotonic wall time and process CPU time surround the same operations.

Calibration probes both variants and selects an identical iteration count for
each pair, targeting the faster variant with a 25% duration margin. Ten adjacent
AB/BA pairs per workload balance process order; workload order also reverses
between rounds. All raw samples are kept. The summary reports each variant's
median/minimum/maximum and every paired ratio; headline percentage changes use
the median of the paired ratios.

The 17 timed cases include:

- SRT: 1, 100, 2,000 and 10,000 plain-text cues; 2,000 multilingual and escaped cues.
- WebVTT: 100, 2,000 and 10,000 plain-text cues; 2,000 multilingual and short-form cues.
- Fallback controls: 2,000 irregular SRT cues and 2,000 three-digit-hour cues in each format.
- Unchanged/error controls: empty SRT, missing WebVTT signature, and reversed/untimed SRT.

The native decision requires a material, repeatable complete-converter gain
for ordinary SRT input: at least 10% median paired CPU reduction and nine of ten
winning pairs in the 100-, 2,000-, and 10,000-cue plain-text cases. All other
cases, including fallback/error controls, are reported and reviewed for costs.
Results from fewer than ten pairs or from Linux are development evidence.

## Correctness

Both baseline and candidate execute the identical three regression suites in
debug and release, with warnings treated as errors and nonzero execution checked.
The new seven-test suite covers every millisecond fraction, rounding carry,
field/separator bounds, per-position malformed characters, Unicode whitespace,
variable-width fallbacks with colliding total byte lengths, and Foundation
string interoperability. Bridging a string does not prove that its UTF-8
storage was noncontiguous; no such branch-coverage claim is made.

The complete-converter corpus checks exact UTF-8 output and typed errors for
1,702 fixtures, including the existing 1,698 escaping/Unicode/line-ending cases.
`TimestampCases.py` reproducibly generates 21,605 additional timestamp cases;
11,101 include independent arithmetic or explicit contract expectations.
`TimestampParity.swift` enforces those expectations and emits the complete
output bytes or exact error for cross-variant comparison. Swift's canonically
equivalent String equality is not used as a substitute for byte equality.

## Results

### Research decision

This branch is retained as independent research and is **not being submitted as
a separate production PR**. During qualification, concurrent
[PR #134](https://github.com/Jagalite/illiquid/pull/134) appeared with the same
fixed-width timestamp optimization, against the same main baseline. Independent
source review found the same accepted timestamp forms, input normalization,
complete digit/delimiter checks, field bounds, integer rounding, contiguous
storage access, and fallback behavior. Helper factoring and digit-check spelling
differ; neither establishes a distinct improvement worth a competing PR.

The broader Linux campaign below also has mixed results, so it does not establish
an additional performance benefit. The candidate, regression coverage, raw
measurements, and independent auditor remain available for review and
reproduction. The two implementations should not be integrated as separate
optimizations. Results from the other PR use different hosts, compilers, and
workloads and are not pooled with this evidence.

### Native qualification status

As of October 28, 2026, 05:25 UTC, this branch's native qualification is queued in
[run 40636743957](https://github.com/Jagalite/illiquid/actions/runs/40636743957),
for source commit `b9a0004d1a3a66ec6efc66c275583d43230001b1`.
The first attempt remained unassigned for about 20 minutes; updating CI to
record Xcode's selected compiler replaced that attempt without changing the
production source or benchmark inputs. No native pass or speedup is claimed
while those jobs are queued.

The other PR's [native run](https://github.com/Jagalite/illiquid/actions/runs/40634454540)
has passed its converter-test and complete-conversion timing steps but is still
running a separate historical-baseline memory step. A successful timing step
alone is not evidence of a speedup, and that run does not qualify this branch's
exact source. No complete application or live-player result is claimed here.

### Linux development evidence

All **248 timed observations** from three development cohorts are retained:

| Cohort | Observations | Purpose and outcome |
| --- | ---: | --- |
| [Initial screen](evidence/linux-initial-screen/) | 28 | Two pairs over seven cases; noisy and potentially overlapped another exploratory task. |
| [Isolated screen](evidence/linux-isolated-screen/) | 84 | Six pairs over seven cases; complete SRT conversions improved about 20–27%, with weaker WebVTT results. |
| [Expanded development run](evidence/linux-development/) | 136 | Four pairs over all 17 selected cases; mixed timings, including regressions in some controls. |

These are separate cohorts, with their original sources, iteration counts and
raw pair ordering recorded in their manifests and receipts. They are not pooled
into a favorable headline or treated as native qualification. The expanded
run's paired CPU changes include −19.7% for 100-cue plain SRT and −20.0% for
10,000-cue plain SRT, but +11.7% for 2,000-cue multilingual SRT, +13.7% for the
irregular SRT control, and +16.8% for the unchanged missing-signature control.
The complete results remain in each `summary.json`; no timed observations were
discarded. The shortest expanded sample used 116.4 ms of process CPU.

Correctness passed in the expanded run: 40 reported tests in each of four
baseline/candidate × debug/release configurations, all 1,702 complete-converter
comparisons, and all 21,605 timestamp comparisons with 11,101 independent
expectations. The measured candidate source SHA-256 is
`98f898002175a58e33dad643b12fb40b4a08f714e7084947f2cca871bf6f8731`.

The [independent auditor](evidence/audit_evidence.py) reconstructs the statistics
and checks the complete cohort, equal work, checksums, baseline/source hashes,
and available full outputs and regression logs. Its
[development audit](evidence/linux-audit.json) distinguishes the complete local
run from the compact retained archives. Its
[18 malformed-evidence checks](evidence/auditor-mutation-checks.json) all fail
as intended. Compact archives keep the complete raw timings and timed receipt
subset; their full verification-file hash is recorded, and the committed
drivers regenerate the larger output corpus.

```sh
python3 Benchmarks/SubtitleTimestampParsing/evidence/audit_evidence.py \
  Benchmarks/SubtitleTimestampParsing/evidence/linux-development
```

Filename-extension normalization was also screened during selection. Although
its isolated classification loop improved, complete folder discovery did not
show consistent gains, so that candidate was not included.
