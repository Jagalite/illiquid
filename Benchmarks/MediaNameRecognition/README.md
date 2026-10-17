# Media filename recognition performance research

This runner compares the complete production `MediaNameRecognition.recognize`
implementation against the exact source frozen from main at
`68274d1b09dcc866296321a5a8858efc297c4f19`. It exercises the filename recognition
component, including Foundation regexes, path handling, and string processing.
It does not simulate these operations or replace them with benchmark-only
implementations.

The baseline is retained in `baseline/MediaNameRecognition.swift` with its Git
blob ID, SHA-256, byte count, source path, and revision in `baseline/manifest.json`.
The default candidate is the current production source. `--candidate-source`
allows independent date-only, tag-only, or other exploratory source variants
without editing the working copy between runs.

## Commands

Run the component tests, exact differential corpus, and balanced timing cohort:

```sh
python3 Benchmarks/MediaNameRecognition/run.py \
  --mode all --pairs 6 --iterations 4000 \
  --output /tmp/media-name-recognition-final
```

Supply `--swiftc /absolute/path/to/swiftc` when the desired toolchain is not on
`PATH`. The runner uses the sibling `swift` executable for package tests. It
supports macOS and Linux with a Swift 6 toolchain and its bundled Testing library.
It does not download or modify toolchains or dependencies.

The output directory must be new or empty. A failed or interrupted cohort stays
in its original directory; rerun into a new one. Do not concatenate incomplete
cohorts or remove observations based on their timings.

Focused correctness only, including all valid supported calendar dates and
nearby invalid boundary values:

```sh
python3 Benchmarks/MediaNameRecognition/run.py \
  --mode test --exhaustive-dates \
  --output /tmp/media-name-recognition-tests
```

A short exploratory cohort for an alternate source:

```sh
python3 Benchmarks/MediaNameRecognition/run.py \
  --mode benchmark --candidate-source /tmp/date-only.swift \
  --pairs 2 --iterations 4000 \
  --output /tmp/media-name-recognition-date-only
```

`benchmark` still performs the complete normal differential corpus before any
timing. It omits the four package test runs. `test` compiles the optimized library
and harness for differential validation, but executes no timing loop. `all` does
both. Measured modes require a positive **even** `--pairs` count so each variant
runs first equally often.

Verify retained receipts without recompilation or a Swift toolchain:

```sh
python3 Benchmarks/MediaNameRecognition/run.py \
  --mode verify --output /tmp/media-name-recognition-final
```

This rechecks source hashes, compressed and canonical corpus hashes, byte-exact
results, successful command/test receipts, timing identities, process order,
full-result checksums, and the summary calculated from raw observations.

## Build and test boundary

The measured recognizer builds as its own optimized `IlliquidCore` module and
dynamic library. A separately compiled harness imports that module and links to
the library through a recorded runtime search path. Both compilation stages use
`-O -whole-module-optimization -swift-version 6 -warnings-as-errors`. This retains
the production caller's module boundary and prevents the optimizer from
specializing the recognizer to the harness's fixture construction.

Each variant also receives a temporary Swift package named
`MediaNameRecognitionQualification`, with the actual recognizer exposed through
the real `IlliquidCore` module name. Every current
`Tests/IlliquidCoreTests/MediaNameRecognition*Tests.swift` file is copied unchanged
into both packages. The same tests run for **baseline and candidate in debug and
release**, with `--enable-swift-testing --disable-xctest`. No test is rewritten to
make a platform-specific substitute pass. Exact test snapshots and full command
logs are retained. Temporary packages, module caches, and products stay under
the output's `build/` directory.

This package is intentionally limited to this Foundation component. It does not
build the complete macOS application, native playback dependencies, or other
metadata consumers. The associated macOS workflow runs the repository's native
integration checks separately; consult that workflow's actual results rather
than treating component success as application qualification.

## Correctness corpus

`Harness.swift` serializes all stored `RecognizedMediaName` properties and all
three computed properties: `seriesTitle`, `displayName`, and `section`. Optional
nil properties use the encoder's consistent omission behavior. The Python
runner compares complete sorted-key JSON lines **byte for byte**, preserving
differences between canonically equivalent composed/decomposed Unicode strings.
It does not rely on Swift's canonically equivalent `String` equality or a hash
alone for the differential comparison.

The normal corpus contains the timed fixtures plus additional combinations of:

- Forward and reversed dates, leap-century cases, invalid months/days, competing
  date tokens, and Unicode digits that regex `\d` accepts but `Int` rejects.
- Every reversed first field from 32 through 99, sampled across 1900, 2000, 2099
  and months 1, 12, 99, preserving the existing invalid-date fallback.
- Unicode titles, decomposed accents, emoji/ZWJ sequences, multiple Unicode
  spaces, full-width brackets, and tag openers followed by combining marks or
  variation selector 16.
- Empty paths, explicit extras, movie-folder hints, catalog IDs, malformed tags,
  nested-looking brackets, adjacent tags, and episode names.

`--exhaustive-dates` adds **184,800 records**: every year 1900–2099, every month
0–13, every day 0–32, and both accepted field orders. This includes every valid
calendar date in the regex-supported year interval and invalid boundary values.
It is **not** exhaustive over all invalid two-digit month/day spellings 00–99.
Both variants' canonical outputs are streamed to gzip files, avoiding a large
uncompressed output-file requirement.

## Timing method

The default is six pairs across eight workloads: **96 fresh processes**, one
measured interval per process. Variant order alternates baseline/candidate and
candidate/baseline between pairs; workload order also rotates between pairs.
The raw data records pair, position, and global process index, and verification
requires the exact expected order and complete matrix.

| Workload | Fixture emphasis |
| --- | --- |
| `dated-forward` | Valid `yyyy-mm-dd` daily program filenames |
| `dated-reverse` | Valid `dd.mm.yyyy` daily program filenames |
| `dated-invalid` | Invalid days, months, leap dates, and reversed fields |
| `dated-unicode` | Unicode program titles and parseable/unparseable date digits |
| `movies` | Ordinary movie titles, years, release information, and folder evidence |
| `episodes` | Season/episode identifiers and multiepisode names |
| `ambiguous` | Unclassified filenames and conservative fallback behavior |
| `tags` | Tagged movies/episodes/dates plus malformed tag inputs |

Each workload has 64 deterministic input strings created before measurement.
Each process performs 128 untimed warmup recognitions by default, consuming all
their output fields before the timed interval. `--iterations` is the number of
recognizer calls per process, **not** the number of corpus repetitions. Choose an
appropriate count on the actual host; 4,000 is a configurable starting point,
not a claim of a fixed duration on every machine.

The interval contains complete recognizer calls and appends their results to an
array whose capacity was reserved beforehand. Every result is retained until
after the interval, when all stored/computed output fields are encoded and fed
to a deterministic FNV-1a checksum. Checksums must agree across every process
for a workload. Fixture generation, reserve-capacity allocation, full-field
serialization, computed display-property evaluation, checksum calculation, and
verification are outside the measured interval. Result-string allocations and
array appends remain inside. The result retention pattern is shared by both
variants but is not a model of live source-browser object lifetime.

Both monotonic wall time and process CPU time are recorded. The summary reports
per-operation medians and ranges, each matched candidate/baseline ratio, and the
median paired ratio. All observations remain in the raw cohort. No timing
threshold is asserted as a correctness test; inspect absolute costs, workload
variation, and repeatability before interpreting a ratio.

Do not run other local performance experiments concurrently with this runner.
Compilation and package tests occur before the timing cohort. Shared-host load,
CPU frequency, allocator state, and Linux/macOS Foundation differences can still
affect measurements. These are component measurements, not demonstrated macOS
UI latency, frame-rate, energy, physical-footprint, or whole-player improvements.

## Evidence layout

| Path under the chosen output directory | Contents |
| --- | --- |
| `environment.json` | Compiler/platform/Python details, checkout state, and settings |
| `sources.json`, `sources/` | Source/test/package snapshots, source origins, hashes, and baseline manifest |
| `build-products.json` | SHA-256 and sizes for each produced library, module, and harness |
| `commands.jsonl`, `logs/` | Exact commands, return codes, elapsed command times, and stdout/stderr logs |
| `test-results.json` | Four component-test receipts, when the selected mode includes tests |
| `differential/` | Compressed canonical outputs and complete-result comparison receipts |
| `measurements.jsonl` | Every fresh-process wall/CPU observation, identity, and checksum |
| `summary.json` | Recomputed medians, ranges, and paired ratios |
| `verification.json` | Final integrity/completeness result |
| `build/` | Reproducible compiler/package/cache products; omit from uploaded evidence |

`--mode verify` works after `build/` has been omitted from an archive. In that
case its original build-product hashes remain recorded receipts; the verifier
explicitly reports how many build products are still present and were checked.
It does not claim to have revalidated the bytes of omitted binaries.

The runner prints concise test status, differential counts, and the timing
summary to standard output in addition to the complete machine-readable files.
Those lines make CI results inspectable even when downloading a workflow
artifact is inconvenient.
