# PlexMatch episode parsing

## Result

A bounded ASCII scanner reduces warm parsing time for the common episode-token
spellings in this native component experiment. The 24-mapping and 1,024-mapping
fixtures were faster in every one of ten paired samples, with median time
reductions of **30.40%** and **21.20%**, respectively. These results support the
small production change; they do not establish end-to-end library-scan or playback
gains.

The experiment compares the complete production parser at baseline
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72` with candidate
`51c04c8985db8f48844ad49b0dc986e45d8d8e57`.
The [native qualification run](https://github.com/Jagalite/illiquid/actions/runs/40634817568)
completed successfully on 2026-10-28. Subsequent changes on this research branch
only record these results and make the research workflow available on demand;
the measured production source, tests, harness, and runner are unchanged.

## What changes

The common spellings, such as `S02E03-E05`, avoid ICU matching, capture-range
conversion, and uppercase-string construction. The scanner admits contiguous,
printable ASCII tokens of at most 19 bytes, the longest valid ASCII spelling.
It accumulates bounded season/episode digits and preserves optional seasons,
specials, range ordering, and exact season matching, including the distinction
between an absent season and explicit season zero.

The original regex remains the fallback for noncontiguous UTF-8, non-printable
or non-ASCII input, and tokens longer than 19 bytes. This preserves ICU's Unicode
case folding, including long-s prefixes such as `ſP01`, and its end-anchor
behavior. An invalid admitted ASCII token is rejected directly; it does not
erase a previous valid mapping for the same path.

Directive/path validation, mapping storage, duplicate replacement, metadata
precedence, and the existing parser limits are unchanged. The production patch
adds 59 lines in `PlexMatchHints.swift`.

## Native measurements

Host: GitHub Actions `macos-26-arm64` image `20261013.0424.1`, macOS 26.6.2,
arm64. Compiler: Apple Swift 6.3.3; Xcode 26.6 selection; macOS 26.5 SDK.
The precise toolchain, source, harness, input, test, and binary hashes are in
[manifest.json](evidence/macos-arm64/manifest.json).

Each value below is the median of ten fresh-process samples, normalized by the
number of full parses in that sample. Times are in microseconds per parse.
A negative time change means a reduction. The percentage is the ratio of the
two medians, not the median of paired ratios; every individual paired ratio is
also retained.

| Fixture | Mapping directives | Bytes | Baseline µs | Candidate µs | Time change | Candidate faster pairs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Metadata only | 0 | 57 | 6.36 | 6.76 | +6.24% | 3/10 |
| 1 mapping | 1 | 86 | 11.25 | 10.22 | -9.16% | 9/10 |
| 24 mappings | 24 | 867 | 123.88 | 86.22 | -30.40% | 10/10 |
| 1,024 mappings | 1,024 | 34,917 | 4538.25 | 3576.25 | -21.20% | 10/10 |
| Near 128 KiB | 3,847 | 131,038 | 16692.74 | 13598.62 | -18.54% | 9/10 |
| 24 Unicode-prefix mappings | 24 | 801 | 122.67 | 121.36 | -1.07% | 6/10 |
| 24 malformed ASCII mappings | 24 | 729 | 72.35 | 49.45 | -31.65% | 10/10 |
| Long invalid token | 1 | 4,056 | 190.75 | 176.76 | -7.33% | 7/10 |

The 24-mapping fixture saves about 37.66 µs per parse on this runner;
the 1,024-mapping stress fixture saves about 962.00 µs. The near-limit fixture
contains 3,847 mapping directives and occupies 131,038 bytes. It is a boundary
stress case, not a claim about typical sidecar size.

### Noise and limits

The strongest evidence is the directionally consistent improvement for
24/1,024 valid ASCII mappings and malformed ASCII mappings. Each wins all ten
pairs, including all five baseline-first and all five candidate-first pairs.

The one-mapping fixture's 9.16% median reduction is less conclusive. Controls
also moved: metadata-only was 6.24% slower, the Unicode fallback was 1.07% faster,
and the long invalid-token fallback was 7.33% faster. Those control results do
not establish small causal gains or regressions. The metadata-only fixture
never invokes episode-token parsing, and its paired ratios range from 0.68 to
1.49. The near-limit baseline also contains a large outlier (60.70 ms per parse);
no samples were removed.

This is one shared CI host run. The 100 ms setting is a **pilot calibration
target**, not a guaranteed duration for final samples: 62 of 160 final samples
were shorter, with a minimum of 52.95 ms. Medians and balanced paired order
reduce sensitivity to noise but do not remove it. The raw distribution is
available for inspection.

These timings measure component parsing cost. The sidecar reader caches parsed
hints within a scan, so the benefit applies when a sidecar is actually parsed,
not on every sibling-file lookup. Disk I/O, complete scan latency, media opening,
playback, frame rate, memory, and energy were not measured.

## Correctness qualification

The same **31-test suite**, as reported by Swift Testing, passed against both
implementations in both debug and release: four successful test runs. It
includes the complete PlexMatch parser, filesystem-sidecar reader, and general
media-sidecar suites. Added cases cover mixed-case and long-s prefixes, zero and
leading-zero seasons/episodes, explicit end-season boundaries, malformed ASCII,
and preservation of an earlier valid duplicate mapping.

A separately compiled optimized driver compared complete metadata receipts for
**6,825 distinct generated tokens**, each parsed in three contexts: a standalone
mapping, inherited metadata with season 7, and replacement of an earlier valid
mapping. All **20,475 corpus parses per variant** matched, including raw and
merged hints, default seasons, descendant restrictions, IDs, and source labels.
Every indexed path in the eight timing fixtures was also compared. The complete
serialized baseline and candidate receipts have the same SHA-256.

Every timed pair additionally had identical input bytes, iteration counts,
warm-up counts, observable checksums, and warm-up checksums. The 160 raw samples
were independently recomputed into the published summary with no discrepancy.
See [tests.json](evidence/macos-arm64/tests.json) and
[parity.json](evidence/macos-arm64/parity.json).

This is native qualification of the affected component, not a full application
build or interactive player test.

## Method

Both variants compile the same five complete production media-library files,
changing only `PlexMatchHints.swift`. The runner checks that the four supporting
files are identical; it does not substitute a simplified parser or a Foundation
shim. Tests and builds run serially in isolated paths.

The library and driver are compiled separately with Swift 6, `-O`, and
whole-module optimization. Runtime input files and an observable scalar consumer
keep the parser result live. Timing includes full public parse, one raw mapping
lookup, the consumer, and teardown inside an autorelease pool. Fixture
generation, JSON input decoding, and warm-up occur outside the timed interval.
The process warms up with up to 16 parses.

Each fixture calibrates one common iteration count using both variants.
Ten fresh-process pairs then run in balanced AB/BA order. The suite interleaves
all eight fixtures in each round. `SWIFT_DETERMINISTIC_HASHING=1` is set equally
for both variants. The method measures warm repeated parsing; it does not
measure cold process startup or first-use regex initialization.

## Evidence

The checked-in compact evidence is extracted from the successful native job:

- [Manifest and hashes](evidence/macos-arm64/manifest.json)
- [Native test receipts](evidence/macos-arm64/tests.json)
- [Complete-output parity receipt](evidence/macos-arm64/parity.json)
- [Summary, ranges, and all paired ratios](evidence/macos-arm64/summary.json)
- [All 160 raw timing samples](evidence/macos-arm64/measurements.jsonl)

The [full native artifact](https://github.com/Jagalite/illiquid/actions/runs/40634817568/artifacts/12794621154)
also contains source snapshots, exact build commands, test/process logs,
calibration samples, and complete semantic receipts. Its workflow retention is
30 days; the compact evidence above remains in the repository.

## Reproduce

Run on macOS 26 with Xcode selected. Use the shared Kyoto queue when it is
available, as required by `AGENTS.md`:

```sh
python3 /Volumes/seed1/Projects/kyoto/kyoto.py submit -- \
  python3 Benchmarks/PlexMatchParsing/run.py --rounds 10 --target-ms 100 \
  --output /tmp/illiquid-plexmatch-parsing
```

Inspect the queued job's show/logs/wait results before reporting completion.
When Kyoto is unavailable, explain that limitation before running the same
Python command directly. Kyoto was unavailable on the ephemeral native runner,
so that run used serial, isolated component builds. The runner requires a fresh
output directory and does not fetch external package dependencies.

The default baseline is the pinned commit above. Pass `--baseline-ref COMMIT`
for a new comparison; the runner resolves the commit and records all input
hashes. The supporting production files must still match the candidate.

The `PlexMatch parsing performance` workflow is an **on-demand research
reproduction** using `workflow_dispatch`. Its optional `baseline_ref` input is
a comparison baseline, subject to that same source-equivalence check. It is
deliberately not a general PR gate against an aging historical baseline. The
regression tests remain in their normal test suite and the existing PlexMatch
regression workflow.
