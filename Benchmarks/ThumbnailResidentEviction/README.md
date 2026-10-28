# Thumbnail resident eviction

This experiment measures the native thumbnail cache's resident-eviction work.
The candidate collects only eviction metadata and snapshots storyboard protection
once per eligible entry. It preserves the existing eligibility checks, sort
priority (unprotected, background, oldest), removal stopping condition, resident
limits, and oversized-insertion behavior.

The baseline is the complete production NativeThumbnailCache.swift from
ea2ff568237e2667f7b1aeee67b11a44ebe95b72, verified against Git blob
66b8127d5c1ea269860b2c1b63e3dcede4262807. Both variants use the same complete
current dependency sources. No platform stubs or replacement cache implementation
are used.

## Run

Use macOS 26 and the repository's supported Xcode toolchain. Fetch the pinned
baseline commit if using a shallow checkout.

    python3 Benchmarks/ThumbnailResidentEviction/run.py \
      --output /tmp/thumbnail-resident-eviction-unique --pairs 10 --target-ms 150

When the shared Kyoto queue is available, submit that command through it as
required by AGENTS.md:

    python3 /Volumes/seed1/Projects/kyoto/kyoto.py submit -- \
      python3 Benchmarks/ThumbnailResidentEviction/run.py \
      --output /tmp/thumbnail-resident-eviction-unique --pairs 10 --target-ms 150

Inspect the queue job, logs, and final result before reporting success. The CI
runner explicitly checks that Kyoto is unavailable before building directly.
Each invocation requires a fresh output directory and serializes all builds.

## Qualification and measurement

The runner builds a dependency-free Swift package from actual Core and Native
source files and runs the focused eviction and existing image-lifetime suites
against both variants in debug and release. It then builds each production
variant as separate optimized shared modules and links the identical driver
against each. The benchmark driver cannot inline the cache implementation.

Before timing, four seeded mixed-operation traces compare all 128 possible
resident keys and exact byte/image counts after each operation: 516 snapshots
per variant. They include promotions, storyboard changes, budget changes, and
varying image sizes. Every timed baseline/candidate pair must also agree on the
operation counts, checksum, final survivor set, and byte/image totals.

Timing uses actual 368-by-208 CoreGraphics images, matching the player's
prewarming size. Workloads cover the default 16 MiB budget, the 96-image cap at
64 MiB, 24 protected storyboard positions, foreground/background insertions,
budget reduction to 8 MiB, and unchanged resident-hit/existing-insert controls.
Images, keys, initial cache fills, and warmup operations are outside the timed
interval. Disk caching is disabled. Unique keys keep insertion workloads on the
eviction path. The budget-shrink scenario reconstructs the cache outside each
timed configure call and sums those measured intervals.

Ten fresh-process pairs alternate AB/BA order. Both variants use identical
iteration counts, calibrated until the faster variant reaches at least 150 ms
of measured work (20 ms for the more expensive-to-prepare budget-shrink case).
The runner retains calibration, raw observations, commands, source/binary
hashes, compiler/SDK/host metadata, complete differential traces, and summaries.
The summary includes per-operation medians, paired ratios, and a deterministic
paired-median bootstrap interval. Timing changes are reported, not used as a
flaky percentage gate.

The workflow separately compiles the full application graph and runs existing
native thumbnail/cache regressions. A compact evidence bundle is printed in CI
logs as well as uploaded, so it can be retained in the repository after the run.

## Scope

These are component timings for cache maintenance. They do not establish
playback frame-rate, end-to-end seek, UI-latency, or application-wide RSS gains.
The resident byte budget and entry cap are unchanged. The metadata list no
longer retains candidate CGImages during trimming; image allocation happens
outside this benchmark, so no process-memory saving is inferred from timings.
The separate memory-pressure eviction method is unchanged.

## Results

Pending native CI qualification. No performance conclusion has been drawn yet.
