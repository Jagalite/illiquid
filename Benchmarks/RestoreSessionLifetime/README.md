# Restoration snapshot lifetime

This experiment exercises the real `PlaybackCoordinator` and its native package
on macOS, using the existing fake playback runtime. It measures the lifetime of
the startup `PlaybackSessionRecord` after its recovery role ends.

## Run

Use the same macOS, Xcode, and pinned native dependencies as the main package:

```sh
python3 Benchmarks/RestoreSessionLifetime/run.py --output /tmp/restore-memory-results
```

The output directory must be new or empty. The dedicated
`restoration-snapshot-lifetime.yml` workflow runs the experiment on `macos-26`
and uploads its logs, source hashes, observations, and summary.

For a source-staging check on any platform:

```sh
python3 Benchmarks/RestoreSessionLifetime/run.py \
  --prepare-only --output /tmp/restore-memory-staging
```

## What is compared

Both variants stage the current package, current coordinator tests, and the same
probe into temporary directories. Only the baseline's complete
`PlaybackController.swift` is read from commit
`6f70cd2446fc6ef38d4e5a0fbf96f91b2234e635`. The runner verifies that this is the
only difference between the staged packages and records SHA-256 hashes.
Production sources are not instrumented or rewritten. `Probe.swift` is appended
to the staged test file to reuse its private fake-runtime fixtures.

The candidate runs the complete coordinator suite. The baseline runs the direct
restoration ownership regression as an expected-failure control, then both
variants run the same successful memory probe. The ownership probe allows either
retention policy; the Python runner checks each variant against its expected
record lifetime.

Two synthetic workloads separate obsolete snapshot ownership from active state:

- **Direct:** restore the saved playlist, then explicitly replace it with one
  stream handled by the fake runtime. No network connection is opened.
- **Folder:** restore a saved folder playlist after its directory contents have
  shrunk to one file. Discovery reconstructs the active playlist; the original
  saved entries are no longer playback state.

Each saved entry has two subtitle URLs. The default counts are 1, 1,000, and
10,000 entries, with four fresh-process pairs per count and workload. Pair order
alternates baseline/candidate and candidate/baseline. The 1-entry case is an
overhead control; large playlists are scaling stress cases.

## Reading the result

The probe samples `malloc_zone_statistics(nil, ...)` at prepared, committed, and
final checkpoints, after pending persistence work retires. Apple's public
[malloc header](https://github.com/apple-oss-distributions/libmalloc/blob/main/include/malloc/malloc.h)
defines a null zone as the sum of all zones. `size_in_use` is live malloc storage;
it is not resident memory, virtual reservation, or a high-water mark.

Each checkpoint also records the retained snapshot's playlist count and the
active playlist count. Reflection is scoped to return scalar counts, so the
measurement does not itself retain the snapshot. The original generated record
is saved in a separate function frame and is not held by a fake in-memory store.

`measurements.jsonl` contains every observation. `summary.json` contains the
median live storage for each variant and the median/minimum/maximum paired byte
reduction at the final checkpoint. No noisy timing or small-fixture memory
threshold determines correctness. The deterministic lifetime assertions and the
coordinator's playback/persistence checks are the correctness gates.

This is a native coordinator experiment with a fake runtime, not an end-to-end
player or decoder benchmark. Active playlists and separately saved shuffle
identities may legitimately share storage with a restored record. Serialized
file size is not treated as live heap size, and no whole-player percentage is
inferred from these fixtures.
