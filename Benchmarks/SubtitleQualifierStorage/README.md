# Subtitle qualifier token storage

## Question and change

Can external-subtitle association retain less temporary memory while keeping
release-specific matching and title ranking unchanged?

`ExternalSubtitleMatcher.associate` indexes tokenized media filenames. The
original media record retains both a raw `[String]` and a normalized `[String]`.
Removing a trailing qualifier such as `1080p`, `WEB`, `DL`, or `x265` mutates a
copy of the raw array. Because both representations remain live, that mutation
creates a second array element buffer. It does not deep-copy every string's
character storage. Filenames without removable qualifiers already share their
array storage in the original implementation.

The candidate retains the raw array and an integer prefix length. The trimming
helpers scan backward and return a borrowed prefix. Indexing and scoring use
short-lived `ArraySlice` views over the raw buffer. Keeping a count in each media
record avoids storing the larger slice representation for every filename,
including unaffected names.

The raw array remains necessary: exact release names and language words in
titles such as “The Last of Us” participate in ranking before normalized-prefix
matching. No slices escape in the URL-only association result. Tokenization,
normalization, qualifier sets, scoring constants, candidate traversal,
cancellation checkpoints, ambiguity handling, and output sorting are unchanged.
The existing fuzzy-scoring `Array(prefix)` allocation is also unchanged.

Swift's documented [array copy-on-write behavior](https://developer.apple.com/documentation/swift/array)
and [shared slice storage](https://developer.apple.com/documentation/swift/arrayslice)
explain the ownership mechanism. The measurements below use the complete
production matcher rather than a simplified array model.

## Comparison and validation

The frozen baseline is commit
`6f70cd2446fc6ef38d4e5a0fbf96f91b2234e635`. Its three component source files
were unchanged on the newer main commit used as this branch's base,
`4abf4b44f13386ccd04f1ce4ad0e756255ca4d14`. The baseline manifest records both
Git blob IDs and SHA-256 hashes; the runner verifies both before compiling.

The runner stages separate Swift packages containing the exact baseline or
candidate matcher, `MediaFileSupport`, and `NaturalFilenameOrdering`. Both use
the same compiler, release settings, fixtures, probes, and deterministic hashing.
They have no external package dependencies. Debug and release tests treat Swift
warnings as errors.

Validation includes the existing matcher, empty-input, and tokenization suites,
plus new tests for long qualifier chains, raw release-name precedence, language
words in titles, qualifier-only stems, exact and fuzzy score values, names
without qualifiers, and cancellation after partial work. The association driver
also checks complete output mappings against independent fixture expectations
and compares baseline and candidate results across 25 fixtures. This includes
natural ordering, Unicode folding, ambiguity, duplicates, unsupported inputs,
and the new plain/mixed qualifier controls.

## Memory protocol

Each of eight workloads runs in six fresh-process pairs, alternating baseline
first and candidate first. Runtime and allocator paths are warmed before fixture
construction. Media URLs remain alive throughout the measurement.

The production cancellation callback supplies a read-only sampling boundary.
For the unique supported media inputs used here, poll `2*N + 2` occurs after
the complete media index is built and before processing the first subtitle.
The callback always returns `false`; the complete association finishes and
every output mapping is verified afterward. A source guard fails if the
relevant cancellation cadence changes. The empty-subtitle control verifies the
existing fast path and intentionally never reaches that index boundary.

The principal measure is `heap_index - heap_before`: live allocator growth
while the complete index is retained. It includes the output dictionary, trie,
and other matcher state, as well as token buffers. It excludes already-live
input fixtures. On macOS, the probe uses `malloc_zone_statistics(NULL)`;
on glibc Linux it uses `mallinfo2().uordblks + hblkhd`.

Resident memory, post-return heap growth, and process peak RSS are retained as
secondary observations. Allocator caching and page granularity can obscure RSS
changes. Peak RSS includes runtime warmup and fixture construction; it is not
an isolated matcher peak. None of these component measurements is a claim
about the whole player's memory usage or a persistent leak.

Nonempty memory fixtures contain three subtitles: an unrelated name first,
then matches for the first and last media file. The release workloads use
`.1080p.WEB-DL.x265.10bit.AAC` suffixes. Controls include suffix-free names,
alternating qualified/plain names, Unicode names, and no subtitles.

## Timing protocol and interpretation

Timing uses ordinary complete association calls without the memory-sampling
callback. It includes result consumption and destruction. Fixture construction,
full-output serialization, and independent-oracle preflight are outside the
timed interval. Both wall time and process CPU time are recorded.

The final protocol targets 250 ms of CPU time per sample and requires at least
five associations even if calibration is slow. Six fresh-process pairs use
balanced AB/BA ordering. The timing driver is derived from the existing
subtitle-tokenization benchmark, with its original cases and oracles retained;
two controls add 4,096 plain filenames and a 50/50 mix of qualified/plain names.
The qualified timing fixtures use the original driver's
`.1080p.WEB-DL.x265` suffix, so their CPU numbers should not be combined with
the memory fixtures as if they were the same workload.

Exploratory runs allowed one association per sample and produced very wide
CPU-time spreads on the shared Linux host, including large variation within
the unchanged baseline. Those results are retained, rather than discarded.
The confirmation run uses the same binaries after validating compiler identity,
all staged source files, package file sets, and binary hashes. The confirmation
runner performs no compilation. Changes in Linux timing medians alone
must not be interpreted as a stable application speedup or slowdown when the
sample ranges overlap substantially.

## Results

### Linux live memory

Swift 6.3.2, x86-64 Linux. Values are median live allocator growth in bytes
across six balanced pairs from the confirmation cohort. The same memory
pattern appears in both retained exploratory cohorts.

| Workload | Baseline bytes | Candidate bytes | Reduction |
|---|---:|---:|---:|
| 16 release names | 12,960 | 9,760 | 24.69% |
| 256 release names | 190,912 | 137,744 | 27.85% |
| 4,096 release names | 3,029,136 | 2,177,232 | 28.12% |
| 32,768 release names | 24,148,240 | 17,332,560 | 28.22% |
| 4,096 plain names | 1,390,464 | 1,390,592 | 128 B increase (0.0092%) |
| 4,096 mixed qualifier names | 2,209,760 | 1,783,808 | 19.28% |
| 4,096 Unicode release names | 3,029,232 | 2,177,344 | 28.12% |

The 32,768-file release fixture saves **6,815,680 bytes (6.50 MiB)** while
the index is live. Plain names differ by only 128 bytes at 4,096 files.
The empty-subtitle fast path does not create an index; its post-return live
allocator growth is **202,288 bytes in both versions**.

### Correctness and CPU

Both production versions passed **35 tests in four suites, in debug and
release**, on Linux. The final driver verified **25 complete association
fixtures containing 14,907 media entries**, with identical baseline and
candidate mappings. Candidate production and test hashes agree across all
three retained Linux cohorts.

**Linux CPU performance remains inconclusive.** The following changes are
the medians of the six within-pair CPU-time ratios, not the ratio of two
independent medians. Negative values mean less recorded CPU time. Large
ranges and inconsistent signs prevent a CPU-neutrality or speedup claim.

| Timing case | Median paired change | Paired range | Candidate slower |
|---|---:|---:|---:|
| `ascii_16` | -8.05% | -53.65% to +39.75% | 2/6 |
| `ascii_256` | -2.09% | -41.05% to +47.68% | 3/6 |
| `ascii_4096` | -7.55% | -47.16% to +18.00% | 3/6 |
| `unicode_256` | -2.80% | -50.04% to +19.18% | 3/6 |
| `mixed_256` | -15.53% | -43.79% to +65.52% | 3/6 |
| `plain_4096` | -12.73% | -43.50% to +156.91% | 2/6 |
| `mixed_qualifiers_4096` | +16.34% | -25.75% to +83.40% | 3/6 |

A bounded identical-binary timing control is retained separately to diagnose
shared-host variability. Its results are not subtracted from the candidate
measurements or used to select favorable samples. Both labels execute the same
baseline binary. Across six balanced pairs with five associations per sample,
the unchanged `ascii_4096` binary produced paired differences from **−44.36%
to +66.35%**; `plain_4096` ranged from **−45.54% to +95.00%**. This demonstrates
substantial measurement variability. It does not establish that the candidate
has no CPU cost. No further Linux CPU reruns were made after this diagnostic.

### Native qualification

[macOS component run](https://github.com/Jagalite/illiquid/actions/runs/40102399772)
was queued when this report was prepared. It uses the same production
candidate and final minimum-five-association timing protocol. Native memory
and CPU results must be read from the completed job; the Linux results above
are not presented as measurements of the macOS application.

### Retained evidence

- `evidence/linux/exploration`: the initial four test runs, original timing
  driver, 23-fixture output parity, and exploratory memory/CPU rows.
- `evidence/linux/controls`: the extended 25-fixture driver with plain/mixed
  timing controls, still using the short exploratory calibration.
- `evidence/linux/confirmation`: the final longer-sample protocol, reusing
  hash-verified binaries from `controls`, with all 96 memory and 84 CPU rows.
- `evidence/linux/aa-control`: the one bounded identical-binary diagnostic,
  with its script, all 24 raw observations, and full-output verification receipts.
- Each cohort contains a runner snapshot, command receipts, source/binary
  hashes, raw rows, summaries, and full-output parity hashes.


## Reproduction

Use Swift 6.1 or newer on macOS 26 or glibc Linux. The native workflow uses
macOS 26 and Xcode 26.6. From the repository root:

```sh
python3 Benchmarks/SubtitleQualifierStorage/run.py \
  --pairs 6 --output /tmp/illiquid-subtitle-qualifier-storage
```

Use a new or empty output directory. To run only the four focused test suites:

```sh
python3 Benchmarks/SubtitleQualifierStorage/run.py \
  --tests-only --output /tmp/illiquid-subtitle-qualifier-tests
```

A further paired cohort can reuse existing binaries without rebuilding:

```sh
python3 Benchmarks/SubtitleQualifierStorage/run.py \
  --skip-tests --reuse-builds-from /tmp/illiquid-subtitle-qualifier-storage \
  --pairs 6 --output /tmp/illiquid-subtitle-qualifier-confirmation
```

When the repository's shared Kyoto queue is available, submit the intended
Python command through it as required by `AGENTS.md`. The Linux research
environment and hosted GitHub runner do not have that local queue; isolated
packages are built serially there.

The runner saves source and binary hashes, compiler details, commands, test
logs, complete verification outputs, raw sample rows, and summary statistics.
The native workflow uploads these as a 14-day artifact. Retained repository
evidence keeps the small text receipts and raw rows; SHA-256 parity receipts
stand in for the multi-megabyte duplicate full-output JSON files. The command
above regenerates the complete outputs.

This qualification exercises the production matching component. It does not
launch the macOS UI, decode media, or measure end-to-end playback memory.
