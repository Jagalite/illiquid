# Open video tab admission qualification

This benchmark compares the exact production tab model and observable tab store
against their versions at commit
`8c3cc3d4008d5d1b8d436bcf2d51d891382b6548`. It measures adding selected media files
to open tabs and updating an existing tab. It does not load media, query a
filesystem, render SwiftUI, or exercise a decoder.

## Run

Use Swift 6.1 or newer with the bundled Swift Testing library and Python 3.10 or
newer. The scripts require no third-party packages, network access, or app build.
The same generated package runs on Linux and macOS; the full application targets
macOS 26.

```sh
# All four behavioral suites against both source variants, debug and release.
python3 Benchmarks/VideoTabAdmission/run.py \
  --output /tmp/illiquid-video-tab-tests --tests-only

# The same tests, followed by the default six paired performance samples.
python3 Benchmarks/VideoTabAdmission/run.py \
  --output /tmp/illiquid-video-tab-benchmark
```

`--swift /path/to/swift` selects an installed toolchain. Builds default to one
job to keep this small qualification predictable; `--jobs` can change that. A toolchain wrapper can
instead invoke the whole Python command so its runtime libraries are available
to the produced executables. `--sizes 1 10` and `--samples 1` provide a small
smoke run. The output directory must be new or empty; evidence is never
overwritten. Build files and raw evidence belong outside the repository.

## What runs

The runner copies the source files without rewriting them into an isolated
SwiftPM package. Its `IlliquidCore` target consists of the real
`OpenVideoTabs`, `MediaSource`, `FolderPlaylist`, `NormalizedFileURL`, and
`NaturalFilenameOrdering` files. Its `IlliquidApp` executable contains the real
`OpenVideoTabStore` plus the benchmark entry point. The module names preserve
the production imports and the tests' `@testable` access. Foundation,
Observation, and Testing are the toolchain libraries; there are no replacement
types or platform shims.

The baseline retains all six selected production files, including the four
dependencies shared by the tab model and store. Its manifest records their
original repository paths, revision, Git blob IDs, and SHA-256 hashes. Every run
validates those hashes and records the current working revision and all staged
source hashes. Baseline dependencies always come from the pinned revision;
candidate dependencies come from the current checkout. The resulting manifests
make any later dependency differences explicit.

Both variants run these repository suites in debug and release:

- `OpenVideoTabsTests`
- `OpenVideoTabResourceIndexTests`
- `OpenVideoTabStoreTests`
- `OpenVideoTabAdmissionTests`

These cover resource identity, Unicode and lexical aliases, remote and relative
URL behavior, malformed enum inputs, close/reopen behavior, independent value
copies, saved array snapshots, resume state, and observation delivery. The
new semantic tests also run against the retained baseline.

## Measurements

Each release subprocess receives a scope (`core` or the actual observable
`store`) and a tab count of 1, 10, 100, 500, or 1,000. The inputs are synthetic,
absolute local file URLs with ASCII episode names in a precomposed Unicode
folder name. All URLs, the folder URL, and the shared playlist are constructed
before the first timer starts.

| Operation | Measured work | State construction |
| --- | --- | --- |
| `unique_add` | Populate a fresh, empty container in source order | Includes container creation and release of the preceding iteration's container; inputs are prebuilt |
| `duplicate_last` | Add the already-open last source repeatedly | Reuses the final container from `unique_add` |
| `record_last` | Update the last source's position, pause flag, playlist, and folder | Reuses that same container and prebuilt playlist |
| `close_reopen_last` | Close, reopen, and select the last tab | Runs at 1 and 10 tabs only |

“Cold” here means admission into an empty tab container. It is not an app launch,
a cold filesystem cache, or a claim about first-playback latency. Small batches
use multiple iterations per timer to improve measurement resolution. Each
`unique_add` iteration is reported as one complete batch; warm iterations are
reported as individual operations.

Checksums and validation run after every measured block. The digest covers
ordered source URLs, source kind, title, resume state, playlist URLs, folder, and
selection membership. It excludes random UUID values. The runner rejects any
checksum mismatch between baseline and candidate, across repeated samples, or
between the core and observable store. The executable also verifies duplicate
UUID stability and the expected post-operation state outside the timers.

The default process order alternates baseline/candidate, then candidate/baseline,
for each scope and size. Six samples therefore give AB, BA, AB, BA, AB, BA. Each
process emits all workloads for its scope/size; reusing setup prevents the
quadratic baseline admission cost from dominating repeated warm setups. The
report contains median, minimum, and maximum nanoseconds per iteration, not a
hard timing assertion.

The normal admission measurement does not retain each prior `items` array
between additions. A consumer that retains an array snapshot can cause Swift
copy-on-write to copy that array during a later append. Snapshot correctness is
tested; the timing result applies to the ordinary synchronous admission loop.
The resource index also adds one normalized key and UUID per distinct indexed
resource. No process-wide memory or end-to-end responsiveness claim follows from
these local timing measurements.

## Evidence

The output contains `environment.json`, per-variant source manifests,
`tests.json`, individual test output, complete command output in
`commands.jsonl`, raw paired observations in `measurements.jsonl`, and grouped
results in `summary.json`. Generated source packages and build outputs make the
execution inspectable. Archive only the compact evidence needed for a review;
build products are reproducible and need not be committed.
