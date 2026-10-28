# Checkpoint source identity

## Question and change

Does repeatedly normalizing the current media URL contribute avoidable work to
session checkpoint construction for large playlists?

PlaybackCheckpoint.record previously compared each visited playlist URL with
the source through NormalizedFileURL.representsSameFile. That normalizes both
URLs for every comparison. The candidate computes the source key once, retains
the original file-URL guard, and still normalizes every visited playlist item.
Decoded items can bypass their normalizing initializer, so direct path or
item-ID comparisons would change the contract.

The measured operation is the complete production record() call, including
playlist deduplication and Date() creation. This is work on the persistence
writer queue. It is not a measurement of video decoding, main-actor latency,
filesystem writes, JSON encoding, playback frame rate, or total player memory.

## Qualification

Results are pending on the research branch. No performance result is claimed
until the paired experiment and correctness checks complete.

## Reproduce

Use Swift 6.1 or newer with Swift Testing available (the Linux workflow uses
Swift 6.3.2). The native workflow uses macOS 26 and the repository's pinned
Xcode environment.

Run compilation through the shared Kyoto queue when available:

    python3 /Volumes/seed1/Projects/kyoto/kyoto.py submit -- \
      python3 Benchmarks/CheckpointSourceIdentity/run.py \
      --output /path/to/new-results --kyoto-queued

Inspect Kyoto show, logs, and wait for that job before reporting its outcome.
On a host without Kyoto, the harness reports that limitation and uses
serialized, isolated builds:

    git fetch --no-tags --depth=1 origin ea2ff568237e2667f7b1aeee67b11a44ebe95b72
    python3 Benchmarks/CheckpointSourceIdentity/run.py \
      --output /path/to/new-results --pairs 6 --target-ms 150

Use --tests-only to run the same debug/release tests and complete-record
differential checks without timing.

## Method

- Pin the baseline to ea2ff568237e2667f7b1aeee67b11a44ebe95b72. All six core
  dependencies must be byte-identical across the baseline and candidate.
- Compile complete production core dependencies and the complete checkpoint
  writer into separate modules. Only the unrelated atomic disk store is
  excluded: the complete PlaybackSessionRecord and PlaybackSessionStoring
  protocol are copied verbatim from their production file.
- Build baseline and candidate in debug and optimized configurations. Run the
  same existing playlist regression suites plus focused checkpoint tests
  against both implementations.
- Compare complete serialized records for every timing fixture across all four
  binaries. Only the nondeterministic updatedAt timestamp is normalized in the
  comparison. The original Date() call remains inside the timed operation.
- Prepare fixtures and perform warm-up before each measurement. Driver and
  production modules are compiled separately; the timed loop consumes the
  returned record. Serialization and full-output fingerprinting occur outside
  the timer.
- Use six balanced AB/BA pairs per workload, with fresh processes and identical
  iteration counts in each pair. Calibrate to the faster pilot with a 50%
  margin. Retain every wall and process-CPU observation, including controls and
  samples below the duration target.
- Include empty and singleton inputs, small playlists, first/middle/last
  matches, absent files, remote streams, and invalid local authorities.
  Large playlists are scaling cases rather than a measured distribution of
  real user libraries.

The output retains compiler commands/logs, source and binary hashes, tests,
compressed full verification records, calibrations, every raw timing
observation, summaries, and a completion receipt. Final checks verify that
sources, tests, harnesses, and binaries did not change during the run.

The dedicated workflow measures this research branch and manual dispatches.
Ordinary matching pull requests run correctness checks and the native
checkpoint/coordinator integration suite without performance timing.
