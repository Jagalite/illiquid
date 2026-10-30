# Persistence-key independent qualification

## Scope and current status

This companion study evaluates the implementation in [PR #144](https://github.com/Jagalite/illiquid/pull/144).
Its production `NormalizedFileURL.swift` is adopted **byte for byte** from that PR;
this companion adds a separate differential corpus, regression slice, and timing study.
The parent study and its measurements remain in [FileIdentity](https://github.com/Jagalite/illiquid/blob/630530f27be150823d4dd4737b15cec947bfd8c9/Benchmarks/FileIdentity/README.md).

**Portable qualification passed. Expanded native qualification is pending.**
The [final Actions run](https://github.com/Jagalite/illiquid/actions/runs/40640731654)
measured revision `9e03582ca516f068e9df0d6e5ed60719d1b83cd2`.
Its [portable job](https://github.com/Jagalite/illiquid/actions/runs/40640731654/job/122658005753)
passed; its [native macOS job](https://github.com/Jagalite/illiquid/actions/runs/40640731654/job/122658005894)
was still queued when this evidence was captured. The companion PR remains a draft
pending the expanded native suite and timing review.
Earlier exploratory results for the unguarded prototype do not qualify this candidate.

| Revision | Identity |
|---|---|
| Original production baseline | [`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`](https://github.com/Jagalite/illiquid/commit/ea2ff568237e2667f7b1aeee67b11a44ebe95b72) |
| Parent PR implementation | [`630530f27be150823d4dd4737b15cec947bfd8c9`](https://github.com/Jagalite/illiquid/blob/630530f27be150823d4dd4737b15cec947bfd8c9/Sources/IlliquidCore/Utilities/NormalizedFileURL.swift) |
| Final measured companion revision | [`9e03582ca516f068e9df0d6e5ed60719d1b83cd2`](https://github.com/Jagalite/illiquid/commit/9e03582ca516f068e9df0d6e5ed60719d1b83cd2) |
| Final qualification workflow | [Run 40640731654](https://github.com/Jagalite/illiquid/actions/runs/40640731654) |

The benchmark resolves the pinned baseline commit and snapshots complete production
files from both variants. Receipts retain source, runner, and driver SHA-256 hashes,
compiler flags/version, platform, locale, candidate Git status, and measured outputs.
Documentation/evidence commits after the measured revision must retain those source bytes.

## What the companion adds

PR #144 already has byte-exact coverage for more than 1,000 raw URL spellings,
constructed paths, basic Unicode/Hangul, one-level relative references, control
characters, NUL, and rejected authorities. Its [tests](https://github.com/Jagalite/illiquid/blob/630530f27be150823d4dd4737b15cec947bfd8c9/Tests/IlliquidCoreTests/LocalMediaSourceValidationTests.swift)
and the nine-file regression slice are retained.

| Additional coverage | Purpose |
|---|---|
| All 256 escaped byte values in multiple positions, cases, and authorities | Exercise decoding boundaries and parser rejection without assuming every spelling constructs a URL. |
| Encoded `.file/id` prefixes and nested relative bases | Check behavior exposed after decoding and multi-stage base resolution. |
| Broader combining, Hangul, canonical-form, and joiner sequences | Detect persisted-byte changes hidden by Swift's canonical string equality. |
| URL Codable round trips | Check identities after serialized URL reconstruction. |
| Playlist sorting and both open-tab suites | Exercise identity tie breaks, admission, alias handling, and index consistency. |
| Four persistence suites | Exercise saved-key lookup, reloading, history policy, content-version changes, and idempotent writes. |

The full native slice has **17 test files and 20 whole production source files**.
It uses Foundation, CoreGraphics, and `os`, plus toolchain Swift Testing/XCTest;
there are no substitute model definitions, native-media dependencies, or app build.
The portable slice runs the focused new identity suite (seven test functions, with
parameterized arguments recorded separately) and the existing folder-lookup
integration script against baseline and candidate sources, in debug and release.

## Differential corpus and pass criteria

[Parity.swift](Parity.swift) makes **65,536 configured construction attempts**.
This number is not a claim that 65,536 URLs were constructed or identities accepted.
Each final receipt separates construction rejection, compared URLs, accepted local
identities, and rejected identities; the table below reports each observed count.

For every constructed URL, the oracle is the unchanged `normalize(url)?.path`.
Both optional results are converted to UTF-8 arrays before comparison, preserving
`nil` and exact bytes. The oracle does not call `persistenceKey`, `item.id`, or
`representsSameFile`. Diagnostics distinguish canonically equivalent byte mismatches.
The corpus requires the configured attempt count, at least 50,000 comparisons, and
zero mismatches. Its two digests summarize outcomes; direct byte comparison determines parity.
Malformed-byte URI spellings use failable construction in the portable corpus.

| Platform/configuration | Attempts | Constructed/compared | Construction rejections | Accepted/rejected identities | Byte mismatches |
|---|---:|---:|---:|---:|---:|
| Linux debug | 65,536 | 65,100 | 436 | 36,630 / 28,470 | 0 |
| Linux release | 65,536 | 65,100 | 436 | 36,630 / 28,470 | 0 |
| macOS debug | Queued | Not run | Not run | Not run | Not run |
| macOS release | Queued | Not run | Not run | Not run | Not run |

## Timing method

[main.swift](main.swift) measures 18 workloads through complete production methods.
Raw-key cases cover short/long/escaped/directory ASCII, NFC/NFD/long Unicode,
encoded components, localhost, relative bases, rejected authorities, file-reference
prefixes, and control characters. Five playlist cases measure last-item or missing
lookups at 1,000/10,000 items, including a Unicode last-item case.

Production sources form a separately compiled optimized `IlliquidCore` module.
The client calls a non-inlined batch function and consumes every returned result.
URL construction, real `FolderPlaylistItem`/`FolderPlaylist` preparation and sorting,
one warmup, oracle work, and JSON serialization occur outside the timed intervals.

Each observation is a fresh process. CI requests **12 baseline/candidate pairs** per
workload, with six AB and six BA orders. Three fresh baseline pilot batches supply
a median for calibration toward **200 ms** of accumulated baseline wall time.
Iterations are shared by both variants and capped at 10,000; the target is not a
minimum duration for the candidate or a guarantee for every workload. Pilots are
retained separately and excluded from summary statistics.

A batch contains 64 key calls or four complete `FolderPlaylist.index(of:)` calls.
The denominator is iterations times calls per batch. Raw-key wall time includes
output-array construction; byte validation and subsequent result destruction are
outside timing. Lookup rows include the production scan and its temporary keys.
POSIX process CPU intervals also include the surrounding wall-clock reads.

Every measured batch is checked against the original-operation oracle. Cross-process
receipts compare exact query/item URL representations, outputs, locale, and operation
counts. The report retains every observation, pair position, per-operation wall/CPU
time, medians, ranges, paired speedups, and faster-pair counts. Compare platforms
within their own paired cohorts, not by combining Linux and macOS absolute times.

## Results and retained evidence

### Linux x86_64: successful component cohort

The measured environment was Swift 6.2.4, Linux x86_64 with glibc 2.39, four logical
CPUs, and Python 3.12.3. The CPU field captured only `x86_64`; no specific processor
model was recorded. CI used the digest-pinned Swift 6.2.4 Noble container recorded
in [provenance.json](evidence/linux-x86_64/provenance.json).

Both original and candidate production sources passed debug and release runs of
the focused identity suite (7 tests in 1 suite) and folder/utility integration slice
(13 tests in 3 suites): **20 tests in 4 suites per source/configuration, or 80 successful
test-function executions** across all four combinations. Parameterized arguments
are additional cases shown in the logs, not additional test functions.

One preliminary baseline run exposed a fixture assumption: this Linux Foundation
rejects an empty relative reference at URL construction. The final fixture tests that
reference when construction succeeds, while requiring all 78 nonempty nested relative
cases. The standalone corpus already records construction rejection explicitly.
The final run, results, and hashes all refer to the corrected fixture commit.

There are **432 timed observations: 18 workloads × 12 pairs × 2 variants**, plus
54 separately retained baseline calibration batches. The shortest accumulated timed
observation was **85.206 ms wall / 85.245 ms process CPU**. All timed batches passed
the original-operation oracle; cross-process receipts matched for every workload.
An independent audit reconstructed all observations and summaries, checked balanced
pair order and completeness, verified result receipts, and matched source/driver/runner
hashes to the pinned measured revisions.

The table uses separate variant medians; **change = 100 × (candidate / baseline − 1)**.
Negative changes mean less time. Pair counts are reported separately; these changes
are not medians of paired percentage reductions. Every workload is included.

| Workload | Unit | Baseline median | Candidate median | Wall change | CPU change | Faster wall pairs | Faster CPU pairs |
|---|---|---:|---:|---:|---:|---:|---:|
| ascii-short | µs / key | 5.791 | 3.265 | -43.61% | -43.57% | 12/12 | 12/12 |
| ascii-long | µs / key | 40.411 | 19.656 | -51.36% | -51.37% | 12/12 | 12/12 |
| ascii-escaped | µs / key | 6.053 | 3.516 | -41.91% | -41.89% | 12/12 | 12/12 |
| ascii-directory | µs / key | 4.844 | 2.984 | -38.41% | -38.37% | 12/12 | 12/12 |
| unicode-nfc | µs / key | 5.788 | 5.855 | +1.15% | +1.17% | 1/12 | 2/12 |
| unicode-nfd | µs / key | 5.914 | 5.995 | +1.37% | +1.36% | 1/12 | 1/12 |
| unicode-long | µs / key | 35.777 | 37.008 | +3.44% | +3.43% | 0/12 | 0/12 |
| encoded-components | µs / key | 6.101 | 3.549 | -41.83% | -41.80% | 12/12 | 12/12 |
| localhost | µs / key | 5.676 | 3.332 | -41.30% | -41.26% | 12/12 | 12/12 |
| base-relative | µs / key | 9.849 | 6.768 | -31.28% | -31.28% | 12/12 | 12/12 |
| rejected-authorities | µs / key | 0.482 | 0.482 | -0.09% | -0.04% | 9/12 | 9/12 |
| playlist-last-1000 | ms / lookup | 6.167 | 3.383 | -45.15% | -45.14% | 12/12 | 12/12 |
| playlist-miss-1000 | ms / lookup | 6.142 | 3.356 | -45.36% | -45.36% | 12/12 | 12/12 |
| playlist-last-10000 | ms / lookup | 62.366 | 34.007 | -45.47% | -45.48% | 12/12 | 12/12 |
| playlist-miss-10000 | ms / lookup | 61.740 | 33.639 | -45.52% | -45.51% | 12/12 | 12/12 |
| playlist-unicode-last-1000 | ms / lookup | 5.725 | 5.803 | +1.37% | +1.37% | 3/12 | 3/12 |
| file-reference-prefix | µs / key | 5.802 | 6.669 | +14.95% | +14.92% | 0/12 | 0/12 |
| control-character | µs / key | 5.631 | 3.245 | -42.36% | -42.33% | 12/12 | 12/12 |

Short ASCII keys improved by 43.61%, long ASCII keys by 51.36%, and the 10,000-item
last-match/missing lookups by 45.47%/45.52% in this Linux cohort. Each of the 12 workloads
with material gains won all 12 wall and CPU pairs. The rejected-authority control was
essentially unchanged (−0.09% wall, −0.04% CPU).

The costs are also consistent enough to retain: NFC/NFD Unicode keys took 1.15%/1.37%
more wall time, long Unicode took 3.44% more (about 1.231 µs per key), and the Unicode
1,000-item lookup took 1.37% more (about 0.079 ms per lookup). The reserved-prefix control
took 14.95% more (about 0.867 µs per key). That control uses `/.file/cache/`, not a live
`/.file/id=` reference; the production guard sends the entire `/.file/` prefix to the
original URL-construction fallback. Ordinary hidden directories do not take that
prefix-specific fallback. The guards add work before fallback, so the broad ASCII
gains do not establish a benefit for all filenames.

### Retained portable evidence

The [original CI artifact archive](evidence/linux-x86_64/artifact.zip) retains
`results.json`, `results.receipts.json.gz`, both differential receipts, all regression
logs, the benchmark log, and compiler details. It is the original 59,312-byte download;
its SHA-256 is
`38349fce47e1385b35a01d2d75a79c7a25bdb157c37397a992b025cb11335ba1`.
The committed archive preserves the evidence after hosted CI artifact expiry.

[Provenance](evidence/linux-x86_64/provenance.json) records the exact run, job, artifact,
source commits, environment, and per-log test summaries.
[The independent audit](evidence/linux-x86_64/audit.json) retains recomputed summaries,
pair counts, source hashes, input hashes, and regressions for all workloads.
The [debug](evidence/linux-x86_64/parity-debug.json) and
[release](evidence/linux-x86_64/parity-release.json) differential receipts are also
available without unpacking the archive.

### Existing parent native evidence: separate corroboration

An independent reconstruction of PR #144's [initial native cohort](https://github.com/Jagalite/illiquid/tree/630530f27be150823d4dd4737b15cec947bfd8c9/Benchmarks/FileIdentity/evidence/native-initial)
checked all 208 observations (13 workloads, 8 pairs), exact paired receipts and
operation counts, and reproduced its paired wall summaries. The
[corroboration record](evidence/parent-native-corroboration.json) also recomputes CPU
reductions. The native cohort measured commit
`6b0b45aa1c5d3efece3bed7defa6245a79ac617b` on an Apple M1 virtual machine, macOS 26.6.2,
and Apple Swift 6.3.3/Xcode 26.6. Its candidate helper SHA-256 is identical to the
companion's production helper.

That narrower, earlier cohort found 25.27% paired wall / 24.67% paired CPU reduction
for escaped ASCII keys and 12.95% / 10.82% for deduplicating 1,100 inputs into 1,000
items. It also found a 2.71% wall / 2.77% CPU regression for its Unicode fallback.
The unchanged normalizer showed an apparent 5.61% wall / 1.39% CPU improvement,
demonstrating noise in that short cohort. These figures are **medians of paired
reductions**, unlike the companion Linux table; they are not combined or used as
native results for the new driver or expanded tests.

The expanded native job remains queued. A Linux pass and this earlier corroboration
do not substitute for running the companion's 17-file native regression slice and
its own 18-workload native timing cohort.

## Reproduce

Run from the repository root with the baseline commit available locally. Use a fresh
output location; the timing runner writes its requested output filename.

```sh
set -euo pipefail
qualification_output="$(mktemp -d "${TMPDIR:-/tmp}/illiquid-key-qualification.XXXXXX")"
swiftc --version
bash Benchmarks/PersistenceKey/check-parity.sh "$qualification_output"
ILLIQUID_KEY_SOURCE_REVISION=ea2ff568237e2667f7b1aeee67b11a44ebe95b72 \
  bash Scripts/test-persistence-key.sh --jobs 2 \
  2>&1 | tee "$qualification_output/tests-baseline.log"
bash Scripts/test-persistence-key.sh --jobs 2 \
  2>&1 | tee "$qualification_output/tests-candidate.log"
python3 Benchmarks/PersistenceKey/run.py \
  --baseline-revision ea2ff568237e2667f7b1aeee67b11a44ebe95b72 \
  --rounds 12 --target-ms 200 --output "$qualification_output/results.json" \
  2>&1 | tee "$qualification_output/benchmark.log"
```

The full test script is macOS-specific because it compiles the complete model and
persistence dependency files. For Linux, use the focused package assembly and
folder-lookup commands in the [qualification workflow](../../.github/workflows/persistence-key-performance.yml).
Both test paths keep current tests while selecting original or candidate production sources.

When Kyoto is available, submit each build command through the shared queue, preserving
its environment, and inspect `show`, `logs`, and `wait` for the returned job ID:

```sh
python3 /Volumes/seed1/Projects/kyoto/kyoto.py submit -- \
  bash Benchmarks/PersistenceKey/check-parity.sh "$qualification_output"
```

Use the same queue wrapper for the regression scripts and Python benchmark runner.
On hosts without Kyoto, the scripts explain its absence before direct compilation.
Each invocation has an isolated temporary build directory and serial configurations.

## Interpretation limits

These experiments measure warm, in-memory identity work. The regression slices check
component behavior; neither slice builds the full player. They do not measure folder
I/O, playback, FPS, visible UI latency, energy, memory footprint, or performance on the
user's Mac. Report regressions and unchanged controls alongside gains, and scope any
conclusion to the measured workloads and runtime.
