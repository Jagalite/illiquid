# Checkpoint folder membership experiment

This experiment compares complete `PlaybackCheckpoint.record()` construction
against `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`. The candidate avoids checking
folder membership when no folder can be saved and normalizes the source URL only
once when a folder membership scan is required.

## Run

Requires macOS 26 and Swift 6.1 or later. Use the shared Kyoto queue when available:

```sh
python3 /Volumes/seed1/Projects/kyoto/kyoto.py submit -- \
  python3 Benchmarks/CheckpointMembership/run.py \
  --pairs 6 --target-ms 50 --output /tmp/checkpoint-membership-results
```

On an isolated host where Kyoto is unavailable, explain that limitation and run
the same Python command directly. The output directory must be new or empty.
Builds and test runs are serialized within the command.

## Method

- Compile the complete checkpoint file and eight complete production core files
  from the pinned baseline and the working tree into isolated Swift packages.
  There are no extracted declarations, replacements, or stubs. Fail if an
  unchanged core dependency differs between the two variants.
- Run the new checkpoint tests and existing playlist deduplication, session record,
  and session store tests against both variants in debug and release.
- Measure optimized executables in six alternating AB/BA pairs. Calibrate each
  workload toward 50 ms using the baseline; large workloads may exceed that
  duration even at one iteration.
- Measure 24 workloads: empty, singleton, 32, 1,000 and 10,000 item cases; folder
  and no-folder first/last matches and misses; remote or unsupported sources;
  and playlists containing only unsupported URLs.
- Construct inputs before timing and consume every returned record. Each
  iteration drains its autorelease pool. JSON encoding, hashing and round-trip
  verification occur after timing.
- Compare a SHA-256 fingerprint of the complete encoded record for every paired
  sample, equalizing only the fresh `updatedAt` field. The driver also checks
  concrete expected folder membership and every other record field.

The artifacts include source snapshots and hashes, environment/compiler details,
test/command logs, calibration, raw observations and a summary. The job log also
contains `CHECKPOINT_TEST`, `CHECKPOINT_RESULT` and `CHECKPOINT_MANIFEST` receipts.

## Scope

Timing includes the existing playlist deduplication in the record initializer,
so record construction still does O(n) playlist work. This experiment does not
time JSON encoding, disk I/O, main-actor scheduling, media decoding, presentation,
or the full player. It does not measure allocation counts, retained/peak memory,
or energy. Reduced repeated normalization is a code-path property; it is not
a measured reduction in process memory.
