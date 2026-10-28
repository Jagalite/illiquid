# Media metadata merge performance

This experiment measures source-attribution work inside complete production
metadata merges and per-episode `.plexmatch` lookups. It builds on the concurrent
[catalog-ID storage PR #163](https://github.com/Jagalite/illiquid/pull/163).
The frozen baseline is its exact `MediaMetadataHints.swift` at
`ed6bf4058bb576cdef36c5ee1b58f4fd85a6374b`. Both variants compile with the same actual
`MediaNameRecognition.swift` and `PlexMatchHints.swift`, so catalog-ID sharing is
already present in both versions and receives no credit in these measurements.

## Change and scope

An episode mapping adds episode identity but no source attribution. The baseline
still constructs a set and sorts the inherited source list on every merge, even
though the common list contains only `".plexmatch"`.

The candidate reuses source attribution when the override is empty and the
inherited array has zero or one entry. Uniqueness and sorting are already
satisfied in those cases. Every other source list retains the previous Set/sort
implementation. The existing catalog-ID helper, identity resets, provider
replacement, parsing, and metadata precedence are unchanged.

The production delta from PR #163 is a guarded assignment in `overriding(_:)`.
The retained array keeps Swift value semantics; regression tests mutate returned
copies and check that their inputs and the parsed index remain unchanged.
The `applying(_:)` benchmarks are unchanged-code controls.

## Reproduce

Use Swift 6.1 or newer and Python 3. The component uses Foundation only and can
run on Linux or macOS without FFmpeg, libass, or an application launch. The Linux
workflow pins Swift 6.2.4's official Ubuntu 24.04 container by digest. The native
workflow selects Xcode 26.6 on macOS 26.

If Kyoto is available, submit the complete command to the shared queue:

```sh
python3 /Volumes/seed1/Projects/kyoto/kyoto.py submit -- \
  python3 Benchmarks/MediaMetadataMerge/run.py benchmark \
  --output /tmp/illiquid-metadata-merge --pairs 8 --target-ms 75
```

Inspect the returned job with `show JOB_ID`, `logs JOB_ID`, and `wait JOB_ID`.
When Kyoto is unavailable, explain the limitation before running directly:

```sh
python3 Benchmarks/MediaMetadataMerge/run.py benchmark \
  --output /tmp/illiquid-metadata-merge --pairs 8 --target-ms 75
python3 Benchmarks/MediaMetadataMerge/run.py summarize \
  --output /tmp/illiquid-metadata-merge
```

Output must be new or empty. Put matching `swift` and `swiftc` executables on
PATH; `--swiftc` or `SWIFTC` selects the benchmark compiler only.
`--tests-only` runs all four baseline/candidate debug/release test combinations
and complete-output verification without timings. Repeat `--case ID` to select
timed cases; full verification still runs.

## Correctness and timing protocol

Both versions run the same independent expected-result tests and existing
PlexMatch regressions, in debug and release with warnings as errors. The driver
compares complete metadata snapshots, including absent fields, content identity,
catalog ID order and duplicates, attribution, and all recognized-name fields.
Parsing and fixture construction happen before timing.

Separate optimized modules contain the actual three production files. The same
driver is linked against each with `-O -whole-module-optimization`, Swift 6
checking, and no cross-module optimization. Each timed iteration visits a pool
of 16 inputs and consumes every returned model with a bounded checksum.
Snapshots, encoding, full comparisons, and receipts stay outside timing.

The baseline calibrates an operation count per workload; the candidate uses the
same count. Eight fresh-process pairs alternate AB/BA order and reverse case
traversal on alternating pairs. Measurements run serially. The summary retains
all paired ratios and their median/range for monotonic wall and process CPU time.
It validates order, operation counts, complete outputs, and checksums again.

Evidence contains the frozen baseline manifest, source snapshots/hashes,
compiler/flags/platform identity, compiled archive/executable hashes, test logs,
compressed complete verification outputs, calibration trials, and every timing
receipt. The dedicated workflow runs measurements on the research branch and
repeats correctness-only checks for pull requests.

These are in-memory metadata merge and lookup measurements. They exclude sidecar
file I/O, XML/text parsing, directory scans, UI responsiveness, native playback,
whole-player CPU, memory, and energy.

## Findings — 2026-10-28

The incremental source-attribution change succeeded in two Linux cohorts. The
primary cohort is [GitHub Actions run 40640236201, Linux job
122656430444](https://github.com/Jagalite/illiquid/actions/runs/40640236201/job/122656430444),
using Swift 6.2.4 on x86_64 Linux. The corroborating local cohort uses Swift 6.3.2
on x86_64 Linux. Both measured candidate
`f2fb1a23fbd942b4672a7c3b72e3b6bb60f9d590` against the frozen #163 baseline.
The later evidence/documentation commit does not change the measured code.

### Primary results

Times below are median nanoseconds per complete API call. The reduction is the
median of eight paired candidate/baseline ratios, so it can differ slightly from
the ratio of the two displayed medians. Each call includes bounded consumption
of its returned model. The same driver is used for both variants.

| Workload | Baseline ns/call | Candidate ns/call | Paired wall-time reduction |
|---|---:|---:|---:|
| Empty attribution, no catalog IDs | 357.5 | 290.2 | 18.5% |
| One inherited source, no catalog IDs | 624.3 | 285.9 | 54.3% |
| One inherited source, one catalog ID | 634.3 | 299.4 | 52.9% |
| One inherited source, three catalog IDs | 629.7 | 299.8 | 52.4% |
| Mapped `.plexmatch` lookup, no catalog IDs | 667.4 | 333.0 | 50.2% |
| Mapped `.plexmatch` lookup, one catalog ID | 677.5 | 333.8 | 50.8% |
| Mapped `.plexmatch` lookup, three catalog IDs | 679.5 | 337.4 | 50.4% |
| Mapped `.plexmatch` lookup with explicit season/range | 693.7 | 350.8 | 49.5% |
| Mapped `.plexmatch` lookup with default season | 676.6 | 339.2 | 49.6% |

Every singleton-source merge and mapped lookup in this table improved in all
eight CI pairs. Process CPU reductions closely match wall-time reductions.
The absolute saving is about 0.33–0.34 microseconds per mapped lookup on this
runner; this is a small component optimization, not an established whole-library
scan or player responsiveness improvement.

The ten unchanged `applying(_:)` cases and two PlexMatch bypass controls have
paired median reductions from **-2.9% to +1.7%** in CI. The six override fallback
controls range from **-0.8% to +1.0%**. Negative reduction means a slower candidate.
`override-add-providers` improves 3.5% and is an affected empty-attribution path,
not an unchanged-code control. Every workload and paired ratio is retained in
the [primary summary](evidence/ci-linux-swift-6.2.4/summary.json).

The local Swift 6.3.2 cohort corroborates the targeted gains: **50.6–54.5%** for singleton-source merges and
**43.6–50.1%** for mapped lookups including explicit/default-season cases. It is
noisier: unchanged-code controls range from -6.1% to +4.3%. Provider-replacement
override controls were 4.0% and 5.1% slower locally, while their CI reductions
were -0.5% and +0.4%. These local slowdowns did not reproduce in the primary
cohort. The complete primary CI cohort is committed, including every control and
timing observation. Local figures are corroborating aggregates; local raw logs
and environment metadata are not published.

### Correctness and qualification

Each cohort passed all four baseline/candidate debug/release configurations,
with **22 tests in two suites per configuration**, including the existing
PlexMatch regression suite. Each also passed **1,274 exact complete-output
comparisons**, followed by **464 validated timing observations** across 29
workloads, 16 inputs per workload, and eight alternating pairs. Output equality,
checksums, operation counts, source hashes, and the summary calculations were
checked independently. The full-output verification digest also agrees across
the two compiler versions.

The native macOS job is **queued, not qualified**, as of this evidence commit.
The PR is a draft until native component validation is available. No full-player
build, native playback/UI test, allocation measurement, or end-to-end library scan
is claimed. This PR targets `codex/catalog-id-storage` and should follow #163;
the catalog-ID optimization and its measurements belong to that base PR.

### Retained evidence

The CI cohort directory includes readable `summary.json`, `manifest.json`, and
`verification.json`, plus a compressed complete raw evidence bundle and its
SHA-256, plus its run identity. The CI bundle is the
exact checksum-verified payload emitted by the successful public job. It
contains all timing receipts, calibration trials, reference outputs, command
records, test/build logs, and compressed full verification snapshots. Its manifest
identifies all nine measured source hashes and the exact candidate commit. The
Actions artifact also retains the CI source snapshots. The repository contains
the exact measured sources at the recorded commit.

To unpack a cohort and independently rerun summary validation:

```sh
python3 - Benchmarks/MediaMetadataMerge/evidence/ci-linux-swift-6.2.4 \
  /tmp/metadata-merge-receipts <<'PY'
import base64, gzip, hashlib, json, sys
from pathlib import Path
source, output = map(Path, sys.argv[1:])
raw = (source / "raw-evidence.json.gz").read_bytes()
assert hashlib.sha256(raw).hexdigest() == (source / "raw-evidence.sha256").read_text().split()[0]
bundle = json.loads(gzip.decompress(raw))
output.mkdir(parents=True, exist_ok=False)
for name, contents in bundle["text_files"].items():
    path = output / name
    assert path.resolve().is_relative_to(output.resolve())
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(contents)
for name, contents in bundle["binary_files_base64"].items():
    path = output / name
    assert path.resolve().is_relative_to(output.resolve())
    path.write_bytes(base64.b64decode(contents))
PY
python3 Benchmarks/MediaMetadataMerge/run.py summarize \
  --output /tmp/metadata-merge-receipts
```
