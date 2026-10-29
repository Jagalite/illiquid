# Sidecar ancestor metadata reuse

This experiment measures complete `MediaSidecarReader.recognize` scans, including
filename recognition, URL/ancestor traversal, real sidecar reads and parsing,
metadata merging, episode mapping, own-file NFO lookup, and result construction.
It compares the actual candidate source with a frozen copy of main
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`, which already includes ancestor path
planning, compact PlexMatch mapping storage, and separate negative caching.

`baseline/manifest.json` records the commit, Git blobs, and SHA-256 of the reader
and all four support sources. The runner verifies those frozen bytes and rejects
changes to any production file other than `MediaSidecarReader.swift`. The two
production modules are built independently with Swift 6, `-O`, and whole-module
optimization. An identical driver calls the public API through a dynamic module
boundary, without cross-module optimization. Native macOS compilation uses the
SDK returned by `xcrun`. Linux screening changes only the reader's `Darwin` import
to `Glibc` and adds the `FoundationXML` import to the NFO parser; original and
compiled hashes record those adaptations.

## Workloads

The main matrix contains 1, 100, and 1,000 sibling episode files at 1, 4, and 12
ancestor folders, including the root. Each ancestor supplies `.plexmatch` with
title, year, season, and all three supported provider IDs, including two IDs for
one provider. The root also supplies `tvshow.nfo`. The last ancestor overrides
prior metadata, while both metadata sources remain represented. The two timed
trajectories are:

- **Cold reader:** Every timed pass creates a new reader and recognizes all its
  files. First sidecar opens, reads, parsing, and subsequent cache hits are timed.
  Reader initialization and destruction are included. OS filesystem caches have
  been warmed; these are not cold-disk measurements.
- **Warm reader:** One reader processes the full fixture before timing, then
  processes that same file sequence repeatedly. This diagnoses cached recognition
  costs separately from the first scan.

Controls cover 1,000 siblings with no sidecars, 100 unique parents with rich
sidecars, and 1,000 files alternating between two rich parents. A common NFO-only
workload recognizes 1,000 siblings at depth 4 with one root `tvshow.nfo` and no
`.plexmatch` files: it inherits title, year, and provider IDs while keeping each
filename's season and episode. Its cold pass reads one sidecar; warm passes read
no additional files. A verification-only fixture combines root descendant
mappings, a leaf mapping, and own-file NFO overrides, followed by ordinary siblings
that must retain their defaults. There are 26 timed cells and 28 verified scans.

Fixture construction, module/regex warmup, calibration, independent expectations,
snapshot serialization, and exact comparisons occur outside timed intervals. The
timed loop retains full results and applies the same small consumer in both
variants. Every sample is a fresh subprocess. The runner calibrates both variants
outside samples, fixes one shared iteration count for each case, alternates AB/BA
order in adjacent pairs, and reverses case traversal on alternate rounds. Wall
time and process CPU time are recorded separately. No attempts are made to drop
OS caches or subtract consumer overhead.

## Correctness and evidence

Both variants must match every stored and computed field of every recognized
result, preserving exact UTF-8 strings and array order. Verification also compares
cumulative `filesRead` after every file, cancellation checkpoint counts, and
every throw-and-resume point in representative cold and primed readers. Independent
assertions check overridden title, year, season, episode, range, provider arrays,
metadata sources, total reads, and expected checkpoint counts. Timed samples must
match verified full outputs, read counts, checksums, and operation counts.

`--run-tests` stages the same sidecar, path-plan, negative-cache, ancestor-hint,
PlexMatch, NFO, and filename-recognition test sources for baseline/candidate ×
debug/release. Platform guards remain intact: a Linux result does not claim that
macOS-only cases ran. Separate packages prevent shared `.build` interference.

The output contains retained build inputs and binaries plus an `evidence/`
directory with source snapshots, original/compiled hashes, source provenance,
compiler identity and flags, binary/library/module hashes, exact compressed
verification outputs, command receipts, calibrations, raw samples, and summaries.
`completion.json` is written only after all requested work succeeds.

## Running

Use the shared Kyoto build queue when available, as required by `AGENTS.md`.
On a host without Kyoto, explain that limitation before a direct build. Serialize
timing campaigns and avoid other builds or benchmarks on the measurement host.

```sh
python3 Benchmarks/SidecarAncestorHints/run.py \
  --output /tmp/sidecar-ancestor-hints-native \
  --run-tests --pairs 10 --target-ms 150
```

A short screening run can select cases without changing the full verification
corpus:

```sh
python3 Benchmarks/SidecarAncestorHints/run.py \
  --swiftc /path/to/swiftc \
  --output /tmp/sidecar-ancestor-hints-screen \
  --pairs 2 --target-ms 80 \
  --case rich-depth4-1000-cold \
  --case rich-depth12-1000-cold \
  --case missing-depth4-1000-cold \
  --case alternating-depth4-1000-cold
```

`--verify-only` compiles and verifies without timing; add `--run-tests` for the
four test configurations. `--rounds` is an alias for `--pairs`. Outputs must be new
or empty so a later run cannot overwrite prior evidence. Linux hosts using a
separate toolchain dependency directory should pass it through `LD_LIBRARY_PATH`;
the runner preserves and records that environment setting.

## Current-source integration regression

Automated `push` and `pull_request` runs use `--current-source-regression`.
This mode accepts only the exact reviewed SHA-256 pins for all five production
sources and validates the frozen manifest, every frozen source, and the unchanged
harness. Both independently built arms use identical reviewed current support;
the reference arm retains the independent frozen reader. Provenance records this
reference adaptation rather than treating it as the historical experiment.

The mode forces all selected current tests for both readers in debug and release,
plus full parity of 28 scans, 12,822 recognized outputs, and 92 cancellation
throw/resume trajectories. Partial `--case` lists and measurement APIs are
rejected. It produces no timing samples or performance claim.

```sh
python3 Benchmarks/SidecarAncestorHints/run.py \
  --output /tmp/sidecar-ancestor-hints-regression \
  --current-source-regression
```

The same Kyoto requirement applies. Manual `workflow_dispatch` and the CLI
default preserve historical strict validation: they reject the integrated tree's
three changed support files. Historical timing reproduction requires the recorded
historical source combination; the integration regression does not replace the
retained reproduction commands or archived evidence below.

## Retained research and final candidate

The [research report](../../Documentation/SIDECAR_ANCESTOR_HINTS_PERFORMANCE.md)
explains why the first two representations were rejected and proposes candidate C
as a research draft pending native qualification. Its 20 added / 3 removed
production lines preserve the original path-plan value and retain nonempty
ancestor hints in a separate immutable snapshot captured before callbacks.

The [evidence index](evidence/README.md) separates all five completed timing
cohorts (1,800 observations) and the three candidates' test receipts. Raw samples
and logs are in `evidence/raw-receipts.zip`; complete differential outputs are
in the shared `evidence/verification-outputs.json.gz`. Hash manifests and exact
source-commit mappings accompany them. These publication copies deduplicate
identical outputs; a normal runner invocation still retains all original files.

To reproduce C's full Linux matrix, use the recorded Swift 6.3.2 toolchain and
`--pairs 10 --target-ms 300`, with CPU affinity 0 as recorded in its context.
Choose an allowed CPU on another host and record that difference. Its final
unchanged-source diagnostic uses:

```sh
taskset -c 0 python3 Benchmarks/SidecarAncestorHints/run.py \
  --output /tmp/sidecar-ancestor-hints-followup \
  --pairs 20 --target-ms 1000 \
  --case rich-depth4-1000-cold \
  --case missing-depth4-1000-cold \
  --case missing-depth4-1000-warm \
  --case nfo-depth4-1000-cold
```

This diagnostic addresses the original matrix's approximately 4% missing-sidecar
control result. It is not a replacement for that matrix or proof of equivalence.
The primed no-sidecar case still leaves a possible modest overhead. No additional
local tuning or timing cohorts followed it; the next qualification is native
macOS through the included workflow.
