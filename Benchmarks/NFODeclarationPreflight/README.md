# NFO declaration preflight

## Result and qualification status

The final candidate reduces complete in-memory NFO parse time on the measured
Linux ASCII workloads: **32.6–38.9%** for the small movie, episode and show
examples, and **87.4–94.9%** for 4–120 KB ASCII plot examples. Every one of
those workloads improved in all eight baseline/candidate pairs.

**Native macOS 26 qualification is pending.** Its runner was still queued when
these results were recorded. Linux timings do not establish macOS performance.
The PR remains a draft until native compilation, tests, and timing controls
have been inspected. This component study does not measure application launch,
folder discovery, filesystem/network I/O, playback, rendering, energy, or memory.

The remaining tradeoff is explicit: documents whose first `!` or non-ASCII byte
occurs after a 32 KB ASCII prefix pay an extra scan before the original searches.
The measured late-`!` case is **19.719 µs / 2.44% slower**; late Unicode is
**21.973 µs / 2.15% slower**. These repeatable costs are not dismissed as noise.
No representative document-frequency distribution was measured, so there is no
weighted overall-library speedup claim.

## Why this area

`MediaSidecarReader` calls `NFOMetadataHints.parse` when reading an uncached NFO
and caches the result for the current background scan. The parser previously
performed two locale-aware searches over every accepted UTF-8 document to
reject `<!DOCTYPE` and `<!ENTITY` before constructing XMLParser.

After the existing byte limit and UTF-8 decoding succeed, the candidate examines
the original Data through a read-only `withUnsafeBytes` closure. Entirely ASCII
input without `!` cannot contain either forbidden marker, so it can skip the
two searches. Any non-ASCII byte, including a BOM, or any exclamation mark
retains the exact original localized searches. Scanning the input avoids
requesting another storage representation from the decoded String.

The XML parser configuration, external-entity setting, field selection, Unicode
behavior, 128 KiB document limit, nesting limit, and per-field text limit are
unchanged. The closure neither mutates the input nor retains a pointer.

## Final Linux observations

- Tested source commit: `915ccf2c6805c9be7575ce0980ca1fe2c40c8414`.
- Baseline parser: `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`, Git blob
  `051c475fd33bcd16ec33f6b4b93ee98fffdb21d3`.
- Host: Ubuntu 24.04 / Linux x86_64, AMD EPYC 7763, Swift 6.4.
- [Successful Linux job](https://github.com/Jagalite/illiquid/actions/runs/40640262780/job/122656865980).
- [Final manifest](evidence/final-linux/manifest.json),
  [summary](evidence/final-linux/summary.json),
  [all calibration and measurement observations](evidence/final-linux/observations.jsonl),
  [command receipts](evidence/final-linux/commands.jsonl).

Times are median microseconds per complete warmed parse plus identical result
consumption. Negative candidate change means less elapsed time. The table
includes every timed workload and all controls.

| Workload | Input bytes | Baseline µs | Candidate µs | Candidate change | Faster pairs |
| --- | ---: | ---: | ---: | ---: | ---: |
| movie-small | 98 | 19.815 | 13.353 | -32.61% | 8/8 |
| episode-small | 126 | 19.170 | 12.192 | -36.40% | 8/8 |
| show-small | 80 | 14.442 | 8.825 | -38.90% | 8/8 |
| unicode-title | 64 | 16.800 | 16.637 | -0.97% | 5/8 |
| bang-title | 53 | 13.430 | 13.405 | -0.19% | 5/8 |
| comment | 67 | 12.298 | 12.254 | -0.36% | 4/8 |
| cdata | 53 | 11.716 | 11.772 | +0.48% | 2/8 |
| doctype-rejected | 85 | 1.687 | 1.697 | +0.63% | 2/8 |
| entity-comment-rejected | 75 | 4.075 | 4.093 | +0.46% | 1/8 |
| malformed | 22 | 9.785 | 5.889 | -39.82% | 8/8 |
| invalid-utf8 | 3 | 0.058 | 0.058 | +0.32% | 3/8 |
| empty | 0 | 2.297 | 1.968 | -14.30% | 8/8 |
| oversized | 131,073 | 0.017 | 0.016 | -4.02% | 8/8 |
| ascii-plot-4096 | 4,167 | 114.883 | 14.461 | -87.41% | 8/8 |
| ascii-plot-32768 | 32,839 | 807.872 | 47.063 | -94.17% | 8/8 |
| ascii-plot-120000 | 120,071 | 2858.959 | 145.128 | -94.92% | 8/8 |
| early-bang-32768 | 32,823 | 804.653 | 806.884 | +0.28% | 3/8 |
| late-bang-32768 | 32,823 | 807.972 | 827.691 | +2.44% | 0/8 |
| early-unicode-32768 | 32,824 | 1203.576 | 1200.405 | -0.26% | 6/8 |
| late-unicode-32768 | 32,824 | 1023.810 | 1045.783 | +2.15% | 0/8 |

The unchanged early-rejection controls can show tiny code-generation or timing
differences. Their nanosecond-scale deltas are not the optimization claim.
Only the targeted ASCII-path improvements and the explicit fallback costs are
used to assess this change.

## Correctness

Both baseline and final candidate passed **69 tests across six suites**, each
run in debug and release (four successful test runs). The suites cover NFO
field selection and episode scope, sidecar integration, media-name recognition,
text limits, and the new declaration-preflight cases.

All **838 differential cases** produced identical complete metadata fields or
rejection results. The stable output SHA-256 for both variants was
`613f8858d7dff65775164b7168bd00a9c09359712d880365f7b0d4cd00cb7d45`.
The corpus includes every ASCII byte in captured and ignored content, ordinary
movie/show/episode documents, declarations in comments and CDATA, Unicode and
numeric character references, seeded generated XML, invalid UTF-8, exact byte
limits, and nesting boundaries. Full outputs and logs are also in the CI artifact.

## Experimental method

1. Verify the frozen baseline parser against its recorded Git blob. Snapshot
   the current shared support sources and tests once for both variants; only
   the parser differs.
2. Compile and execute both variants' tests in debug and release, serially
   within each host. macOS source/test copies are unmodified. Linux adds
   FoundationXML/Glibc imports; the existing legacy directory-hint adapter is
   applied if needed. Original and compiled hashes are recorded.
3. Build optimized production dynamic libraries with `-O
   -whole-module-optimization -swift-version 6`. Compile the driver separately,
   without cross-module optimization. Binary hashes are retained.
4. Compare every differential output field. Construct benchmark fixtures
   outside timing and perform three untimed warmups in each fresh process.
5. Calibrate baseline batches toward 100 ms, then use the same iteration count
   for both variants. Run eight pairs in alternating AB/BA order. Consume every
   result inside timing; serialize receipts afterward.
6. Preserve every calibration and measurement observation, source/toolchain
   receipt, and the full table of controls. Do not pool different source cohorts.

These are short component microbenchmarks on shared CI hosts. Repeated paired
observations establish the reported directional gains; exact magnitudes should
be remeasured on the target Mac and on representative NFO collections.

## Earlier experiment

The initial `text.utf8.contains(where:)` scanner improved the targeted cases but
regressed the two late-trigger controls by 7.6% and 6.0%. That result motivated
the direct-byte implementation. Its [raw evidence](evidence/initial-linux/README.md)
is retained separately and is not used for the final candidate's numbers.

The first CI attempt encountered a test-report receipt mismatch after Swift
reported a successful test command: Swift 6.4 includes a suite count in its
summary. The runner now accepts both formats while requiring a positive test
count, a passing summary, and the expected suite. No timings from that failed
attempt are included. An intermediate String.withUTF8 implementation was
prepared but is not used for the reported final results.

## Reproduce

Use Swift 6.1+ and Python 3.10+ with a fresh output directory:

```sh
python3 Benchmarks/NFODeclarationPreflight/run.py \
  --pairs 8 --target-ms 100 --output /tmp/illiquid-nfo-preflight
```

Follow root `AGENTS.md`: submit the whole command through Kyoto when it is
available, then inspect the job, logs, and completion. On the isolated GitHub
runners Kyoto is absent; the harness reports that limitation and serializes
its direct builds in separate package directories.

`--tests-only` runs tests and differential verification without timing.
The workflow runs the complete tests and benchmarks on branch pushes and
pull requests so native performance qualification remains part of the PR.
Raw receipts are printed in job logs and uploaded as artifacts for 14 days;
the reported Linux evidence is also committed here for durable review.
