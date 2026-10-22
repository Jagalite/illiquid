# Recursive media scanner benchmark

Compare the production `SourceRecursiveMediaLoader.read` with its original
implementation at `7f9ba073394b77a908e0589447c6edc8d10b832c`. The optimization
discards directories, nonregular entries and known unsupported nonlinks before
resolving their filesystem identity. Supported original extensions are reused
only when resolution preserves the URL's exact UTF-8 spelling.

## Run

Use Python 3.9 or later and Swift 6.1 or later. Native qualification uses macOS
26 and the repository's pinned Xcode. The isolated package has no downloaded
dependencies and does not build the player SDKs.

```sh
# Both variants' debug/release tests, optimized builds and eight AB/BA pairs.
python3 Benchmarks/RecursiveMediaScan/run.py \
  --pairs 8 --jobs 2 --output /tmp/recursive-media-scan

# Correctness only, with the same production declarations and frozen baseline.
python3 Benchmarks/RecursiveMediaScan/run.py \
  --mode test --output /tmp/recursive-media-scan-tests

# Timings only; increase the synthetic filesystem fixture sizes proportionally.
python3 Benchmarks/RecursiveMediaScan/run.py \
  --mode benchmark --scale 2 --pairs 8 --iterations 3 \
  --output /tmp/recursive-media-scan-large
```

Output must be a new or empty directory. `--swift /path/to/swift` selects a
toolchain; no toolchain path is embedded in the runner. `--case` can be repeated
to select workloads. `--pairs` accepts a positive even count; fewer than eight
pairs are marked exploratory. `--configuration debug` or `release` restricts
test configurations. `--mode prepare` stages and hashes sources without building
or measuring them; `--mode build` stops after the optimized builds.

## Fixtures

All fixture creation occurs before measurements. Default sizes are:

| Case | Inputs and purpose |
| --- | --- |
| `supported_only` | 1,000 media files in 20 directories; control for added work on accepted entries. |
| `supported_unicode` | The same 1,000-file shape using composed/decomposed accents and Japanese in directory/file names; exercises exact-byte reuse and normalization fallback. |
| `mixed_90percent_nonmedia` | 2,000 files, 200 media and 1,800 artwork/text/subtitle/NFO entries. |
| `directory_heavy` | 1,230 directories and 120 media files; measures avoided identity resolution for directory entries. |
| `symlink_controls` | Root alias; ordinary files; extensionless, misleading, chained and broken links; linked directory; Unicode names; hidden entries; package and FIFO. Admission is compared with the baseline on the same host. |
| `explicit_overlap` | Overlapping and repeated roots, explicit duplicates, and unsupported/missing explicit files; preserves original admission, order and metadata. |
| `metadata` | 42 media files with movie/episode/show NFO hints, edition/variant naming and extras; includes requested sidecar recognition in the measured scan. |

The first four fixtures isolate the primary performance tradeoff. The last
three exercise semantic paths, and their small timings should not be interpreted
as whole-player improvements. `--scale` multiplies primary file counts and most
control contents. Files are empty except for bounded synthetic sidecar text.
Symlink and package resource values can differ between Foundation platforms;
the harness compares actual baseline and candidate results on the same host.

## Timing and complete result checks

Each member of an AB/BA pair runs in a fresh process, warms its own Foundation
state with a complete scan, and performs three timed scans by default. The
runner alternates process order evenly. Both monotonic elapsed time and process
CPU time surround the production `read` call, including discovery, filtering,
identity resolution, deduplication, and optional metadata reading.

Fixture creation, input decoding, warm-up, receipt encoding and comparison are
outside both clocks. Every measured result is consumed and checked against its
retained complete receipt. A separate diagnostic scan first writes one full
receipt per fixture and variant; the runner requires those two receipts to be
byte-identical. Receipts preserve entry order and include absolute URL,
visibility path, kind, exact floating-point timestamp bits, and every stored
recognized-media field. Measured samples contain only compact diagnostics and
the verified receipt hash, so full receipts are not duplicated in every log.

Summaries retain individual scan times and each process's mean scan time, then
report baseline/candidate medians and ranges plus the median paired ratio. The
console prints compact CPU and elapsed-time results for CI review. Measurements
describe warm local filesystem scans, not cold disks, network volumes, SwiftUI
rendering, playback resource use, or complete application startup.

## Sources and correctness tests

`baseline/SourceRecursiveMediaLoader.swift` is a verbatim enum extraction from
the original revision. Its manifest records the revision, source path, source
Git blob, full-file SHA-256, extraction boundaries and enum SHA-256. The frozen
enum hash is `9e1cda72a1b4280d25c9aed86bfd3d62fe2385c773aff115e5b6370e54e93639`.

The runner reuses the guarded `snapshot()` helper from
[`SourceTreeVisibility/run.py`](../SourceTreeVisibility/run.py) to stage actual
current Foundation declarations and dependencies. It does not use that
benchmark's historical baseline or implementation. The candidate scanner is
copied without edits from the current production source. The baseline replaces
only that entire enum with the retained original. The runner verifies that all
other staged source bytes are identical between variants, and records the
extractor, driver, production inputs, staged sources and executable hashes.

The isolated tests are the repository's `SourceRecursiveMediaLoaderTests` and
`SourceMediaOrganizationTests`, run against both variants in debug and release.
They check expected behavior independently of paired benchmark receipts. Test
targets link only the library modules; the benchmark command-line entry point
is in a separate executable target.

On Linux only, staging changes the Darwin import to Glibc, adds FoundationXML,
and supplies an explicit directory hint in the existing sidecar organization
test's temporary root. These are the same guarded portability adaptations used
by the source-tree benchmark. Production files and macOS sources are unchanged;
every adaptation is recorded in the source manifests.

## Evidence

The `evidence/` directory is suitable for CI upload. It includes environment
details; exact commands; test logs; source/binary hashes; raw per-scan samples;
compact summaries; one full receipt per fixture/variant; fixture specifications;
the runner, driver, extractor and baseline; and compressed staged source packages.
Compiler caches, built binaries and filesystem fixture trees are excluded.
The output directory retains those larger intermediates for local inspection.
