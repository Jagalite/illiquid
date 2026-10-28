# Shuffled checkpoint identity reconciliation

## Question and scope

While shuffle is enabled, PlaybackCoordinator.checkpointSession reconciles the
saved base order on the main actor. The old expression restores complete playlist
items and immediately maps them back to IDs. This study compares that complete
expression with a dedicated ID-only helper, using exact production source from
baseline ea2ff568237e2667f7b1aeee67b11a44ebe95b72 and the checked-out candidate.

The helper preserves first-occurrence identity bytes, surviving saved order and
the current order of additions. With a saved order, it avoids the full-item
dictionary/result and repeated normalization of surviving IDs. The empty-base
path also avoids a second normalization pass, except for the baseline's existing
empty/singleton fast paths. A Set and ID arrays remain; both paths
have expected O(N + S) time and O(U) auxiliary storage. Empty and singleton paths
are included as controls. This is a transient-work optimization, not a claim of
measured retained-memory, RSS, playback FPS or complete checkpoint/UI latency.

## Reproduction

Use the shared Kyoto queue when available, preserving the command/environment:

    python3 /Volumes/seed1/Projects/kyoto/kyoto.py submit -- \
      python3 Benchmarks/CheckpointIdentities/run.py \
      --pairs 12 --target-ms 150 --output /tmp/checkpoint-identities

Inspect Kyoto show/logs/wait before reporting a result. Where the shared queue
is unavailable, explain that limitation first, then run the same Python command
directly. The hosted macOS workflow checks and records its absence. Each build
uses its own scratch directory, and all builds within the component job are
serialized.

The runner compiles four exact core files into IlliquidCore, with a separate
caller module to preserve the production module boundary. Both variants use the
same harness and tests; CHECKPOINT_BASELINE selects the old caller expression
and test adapter. It runs debug and release tests with Swift 6 checking and
warnings as errors. It does not modify the app package or fetch new dependencies.

## Correctness and measurement method

The independent integer-label oracle covers 41,261 current/saved sequence pairs.
Other tests cover duplicates, removed entries, additions, successive edits,
normalized aliases, decoded unsupported URLs, remote query/fragment identities,
and current NFC versus saved NFD byte representation. The original expression
must pass the same tests. Existing full-item restoration and ordering tests
continue to run.

A separate native app-graph job exercises shuffled removal, append, checkpoint,
shutdown, relaunch and unshuffle through the real coordinator with its existing
fake backend. This does not qualify live media decoding or visible UI behavior.

Sixteen benchmark workloads include empty/singleton controls, 16/256/4,096-item
queues, edited queues, duplicated input and saved IDs, empty saved order, long
Unicode paths and a duplicate-heavy boundary case. Fixture creation is outside
timing. Every process verifies all ordered UTF-8 output bytes against its
independent expected result before and after timing.

Each case uses 12 fresh-process baseline/candidate pairs with balanced AB/BA
order and a common iteration count calibrated toward 150 ms of process CPU
time for the slower variant. CPU and monotonic wall times include the complete expression, result
destruction and a small identical rotating result consumption. Full checksums
are outside timing. No timing samples are discarded.

The output retains source and binary hashes, toolchain/platform details, exact
fixture outputs, test/build logs, calibration records, all observations, paired
summaries and deterministic bootstrap intervals for the median paired ratio.
Intervals describe variation on the measured host; they are not cross-device
guarantees. Output directories must be new or empty to preserve earlier attempts.

## Results

Measurements are pending the initial native CI run. No performance result is
claimed by this initial research commit.
