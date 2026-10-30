# Batch-open selection performance

## Question and change

When a prepared playlist is applied, `PlaybackController.applyOpenPlan`
selects the current file with `PlaylistMutation.indexPreservingCurrentIdentity`
and then scans the same items again to decide whether playback can continue.
The helper already prefers the first matching identity over its fallback.
Comparing only its selected item preserves that distinction and removes the
second linear scan.

For a valid local target found after visiting N items (N > 1), the old
composition performs N + 1 normalizations in the selection helper and 2N in
the preservation scan. The candidate performs N + 3 in total. These are
operation counts; elapsed times must come from the benchmark.

The singleton check remains necessary: the selection helper returns index 0
without proving that the sole item matches the current file. Nil and invalid
targets still do not count as matches. An explicit replacement after Stop
continues to create a new session through the unchanged
`reopensStoppedSelection` condition.

## Reproduction

The baseline is current main at
[`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`](https://github.com/Jagalite/illiquid/commit/ea2ff568237e2667f7b1aeee67b11a44ebe95b72).
It already contains the earlier playlist identity lookup optimization. Only
this caller's selection-plus-preservation block differs between variants.

On an isolated Swift host with the baseline commit available:

```sh
python3 Benchmarks/BatchOpenSelection/run.py \
  --pairs 8 --target-ms 50 --output /tmp/batch-open-selection
```

The output directory must be new or empty. The runner refuses direct builds
when the shared Kyoto installation is present; shared-host builds must be
coordinated through Kyoto. The dedicated GitHub Actions workflow runs on an
isolated macOS 26 host, checks build coordination, and builds serially.

## Method

- Extract the exact selection block from both complete controller snapshots,
  with unique marker checks. Preserve snapshots, extracted source, source
  hashes, compiler commands, binary hashes, and platform details.
- Require the four shared helper source files to match the baseline byte for
  byte. This avoids crediting prior or unrelated core optimizations.
- Compile the component as a separate dynamic Swift module and the driver
  independently, without cross-module optimization.
- Verify 2,102 independently expected index-and-preservation results in
  baseline/candidate debug and release builds before admitting timed samples.
  The corpus includes 341 small queues, decoded raw URL aliases, Unicode,
  unsupported authorities, duplicate identities, and different paths.
- Construct fixtures outside timing, warm up the operation, then measure both
  result fields through a checked checksum.
- Calibrate both variants to one shared iteration count for each workload.
  Run eight pairs in fresh processes, alternating baseline-first and
  candidate-first order. Retain every calibration and measurement separately.
- Report all 20 workloads, including empty, singleton, first-match, and
  nil-target controls. Unsupported-target results are edge cases rather than
  representative ordinary playback workloads.

The companion native job compiles the full application test graph and runs
`PlaybackCoordinatorTests` and `PlaylistIdentityLookupTests` in debug and
release configurations. New controller cases check singleton/middle/last
preservation in replace and append modes, continuing event ownership, and a
missing-current replacement. Existing coverage checks reopening after Stop.

## Scope

This experiment measures the synchronous selection computation during batch
open. It does not time directory discovery, filesystem preparation, decoding,
first-frame presentation, or live UI interaction. The extracted component
receipt explicitly records that it does not compile the full controller;
the separate native test job supplies that integration check.

## Evidence

Results and qualification links will be recorded here after the research
branch completes its native checks.

## Current-source CI regression mode

Automated push/PR component jobs pass `--regression-only`. This mode retains
`ea2ff568`'s exact extracted selection-plus-preservation block as the baseline
oracle and the current controller block as the candidate. All four support
files are captured once from the current working tree and used byte-for-byte
in both modules. The manifest identifies this policy, the historical support
hashes, each snapshot's origin/hash, and both controller extractions.

Both modes verify all 2,102 independent cases in debug and release, retain every
case's exact selected index and preservation flag, compare the complete output
across all four builds, and require all 20 workload definitions. Two separately
compiled candidate release mutations (nil selected index and false preservation)
must be rejected by the correctness oracle; compile failures or timeouts do not
count as successful negative controls.

Regression mode returns before calibration or measurement and writes no timing
samples, command durations, or performance claims. The default command and manual
workflow dispatch still require historical byte-identical support and retain the
complete paired performance workload. They intentionally reject support drift;
regression qualification cannot establish a historical speedup. The component
runner remains restricted to isolated hosts without the shared Kyoto install.
