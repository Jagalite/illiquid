# File identity keys and playlist lookup

This benchmark compares the actual `NormalizedFileURL.persistenceKey(for:)`
implementation and `FolderPlaylist.index(of:)` against frozen production sources
from `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`.

The production change skips a redundant file-URL construction for ordinary
contiguous ASCII paths. Authority validation, lexical standardization, and the
Foundation constructor fallback for Unicode and special path representations
remain part of the measured implementation.

## Run

Use the repository's shared Kyoto queue for compilation when it is available:

```sh
python3 /Volumes/seed1/Projects/kyoto/kyoto.py submit -- \
  python3 Benchmarks/FileIdentityKeys/run.py \
  --pairs 12 --target-ms 250 --output /tmp/illiquid-file-identity-results
```

On an isolated host where Kyoto is unavailable, run the inner Python command
directly. The host needs Swift 6.1 or newer and Python 3; no package downloads,
player SDKs, media files, or network access are required. The output directory
must not already exist. Keep builds and timing campaigns serialized.

Use `--parity-only` to compile both implementations and verify behavior without
timing. Repeated `--case NAME` arguments restrict measured workloads. `--pairs`
must be even; `--swiftc PATH` selects the compiler. The default campaign includes
all 17 cases.

The focused production regression slice runs debug and release tests:

```sh
bash Scripts/test-file-identity-keys.sh --jobs 2
```

Set `ILLIQUID_KEY_SOURCE_REVISION` to the frozen revision to run the same tests
against the baseline. These commands also belong in Kyoto when available.

## Correctness and scope

`Differential.swift` compares optional persistence keys by exact UTF-8 bytes,
including rejected authorities, percent escapes, directory flags, unusual slash
shapes, NULs, controls, Unicode, bridged URLs, and relative and nested bases.
Native macOS adds reachable file references before and after renaming their
files and directories. String canonical equivalence alone is insufficient for
checking persisted key bytes.

`Driver.swift` compares complete workload receipts before timing: all input
keys, ordered playlist URLs and identities, query URLs, and selected indices.
The driver independently verifies the intended first, middle, last, missing,
empty, and rejected-query outcomes. Every timed process checks its output and
the unchanged receipt again after measurement.

The measured operations are warm in-memory key creation and actual playlist
lookups. Fixture creation, playlist construction and sorting, full receipts,
warmup, and verification are outside the timers. The production calls, identical
driver loops, result consumption, and (on macOS) the measured batch's autorelease
pool drain are inside both wall and process-CPU intervals. These measurements
do not establish filesystem scanning, persistence-write, visible UI, or playback
performance.

## Sampling and reproducibility

- Baseline and candidate compile as separate optimized Swift modules and objects.
  The driver compiles separately, with Swift's default cross-module optimization
  enabled and no explicit CMO flag. Inspection of the measured Linux executable
  confirms that production calls remain inside the repetition loops. The baseline
  manifest verifies all three frozen sources; shared playlist/sorting support
  must be byte-identical to the candidate.
- Each observation runs in a fresh process after warmup. Adjacent baseline and
  candidate observations perform identical work, with balanced AB/BA order.
  A fixed seed shuffles case order in each paired round.
- Baseline-only calibration chooses an equal operation count for each pair,
  targeting 250 ms of baseline process CPU by default. Calibration is retained
  separately from the fixed-work observations.
- All observations are retained. Results include absolute per-operation costs,
  median paired percentage changes, ranges, faster-pair counts, and seeded
  bootstrap intervals. A median paired change need not equal the percentage
  change between the two separate medians.
- The manifest records platform/toolchain details, actual compiler frontend
  hashes, source and executable hashes, exact commands, source snapshots, and
  the measurement boundary. The runner fails if a candidate source changes
  during the campaign.

Process CPU excludes time spent descheduled, but frequency, cache state, and
other host activity can still affect both clocks. Native macOS validation is
required because Foundation's URL behavior differs across platforms.

See [the research report](../../Documentation/FILE_IDENTITY_KEY_PERFORMANCE.md)
for the completed results and qualification limits.

## Retained evidence

The checked-in `evidence/linux/summary.json` contains all 17 workload summaries.
Its `qualification.zip` retains the original manifest, exact source snapshots,
all command logs, correctness receipts, calibration records, observation data,
pair schedule, audits, and focused test logs. `archive.json` records the ZIP's
SHA-256 and exclusions. The large compiled products and module caches are
excluded; executable hashes remain in the manifest and the independent Linux
audit verified them before archival.

The initial failed native test compilation is retained separately under
`evidence/native-initial`. It produced no timing observations.

The native audit script accepts explicit locations for a checkout containing
the frozen baseline revision, the extracted benchmark data, and the immutable
source index. This allows its source, calibration, and statistical checks to
be repeated without relying on the original research host's paths. Native
compiled products are excluded from the workflow artifact, so that audit
cannot independently inspect their bytes or generated machine code.

After downloading and extracting the native workflow artifact, run its
independent audit from a checkout that contains the recorded baseline commit:

```sh
python3 Benchmarks/FileIdentityKeys/audit_native.py \
  /tmp/file-identity-keys-macos/benchmark
```

`--repo`, `--source-index`, and `--tests-root` can override those locations.
The supplied source index pins the native qualification commit
`925940f398ead7206c24c616ea02c448629a8360`. The audit script is prepared; a
successful native audit is not claimed while that workflow remains queued.
