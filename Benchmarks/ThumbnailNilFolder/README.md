# Thumbnail ranking without a focused folder

This study compares the production ranking policy at
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72` with a short circuit that avoids
constructing a parent URL and path when the requested folder is nil.

## Production scope

`ThumbnailBackgroundScheduler.runPass` ranks the whole pool before the
starvation-free pass cursor chooses a batch. `SourcesSidebar` supplies a nil
folder for file-only source tabs without a focused folder. Such tabs can still
project 2,048 discovered files. This is opt-in, idle/paused background library
work; it is not called for every video frame or for ordinary current-video
thumbnail preparation.

The nonoptional parent path can never equal a nil folder path. The candidate
keeps the original comparison when a folder exists. Scoring, exclusions,
first-occurrence duplicate handling, stable ties, and full-pool ordering are
unchanged.

## Reproduce

Use macOS with a Swift 6 toolchain and Python 3.10 or later. The workflow uses
macOS 26 and Xcode 26.6. Output directories must be new or empty.

    python3 Benchmarks/ThumbnailNilFolder/run.py \
      --output /tmp/thumbnail-nil-folder --pairs 8 --target-ms 200

For correctness and linkage checks without performance measurements:

    python3 Benchmarks/ThumbnailNilFolder/run.py \
      --output /tmp/thumbnail-nil-folder-tests --tests-only

Use the shared Kyoto queue when it is available, as required by `AGENTS.md`.
The ephemeral hosted workflow has no Kyoto installation and runs builds
directly and sequentially. Do not run another measurement workload concurrently
on the same host.

## Method

The frozen baseline is verified against Git blob
`cf3b96706f34ba5c43041d650f4c9f6217e340cc`. The full baseline and candidate
production files are each compiled into a separate optimized dylib.
The separately compiled driver calls the non-inlinable public ranking
function with runtime inputs. Variant-specific rpaths and recorded load
commands establish which library each driver uses.

The existing `NonDecodePerformance/PolicyHarness.swift` corpus is reused with
this immediate baseline: 4,218 full ordered-output comparisons in both debug
and release. Only the legacy type names are changed for that differential
executable. The timed libraries use unmodified complete production source.

Twelve native workloads combine 32, 256, or 2,048 discovered files; nil or
present folder; and zero or sixteen exclusion roots. Inputs follow the
scheduler's overlapping current, visible, discovered, neighbor, and recent
groups, with at most 32 visible, nine neighbors, and 128 recent metadata
entries. Some history has expired, and most large-pool discovery entries have
no history. One exclusion root matches a real fixture subfolder.
The evidence separately records discovered, total candidate, unique, and result
counts. Results are compared only within the same workload.

Fixtures, URL construction, warmup, and ordered-output verification occur
outside timing. The timed loop consumes output counts across the module
boundary. Each case uses one shared iteration count calibrated so the faster
variant takes at least 200 ms. Eight adjacent process pairs alternate AB/BA,
and case order rotates across pairs. Raw timings and both order groups are
retained. Timing summaries report per-call wall time and paired reductions;
they are not tail latency, allocation, memory-footprint, battery, or live UI
measurements. No noisy speed threshold is enforced in CI.

The workflow also builds the full app graph with the pinned native SDK and
runs the existing `ThumbnailPolicyTests`,
`ThumbnailSchedulingPolicyRegressionTests`, and
`ThumbnailBackgroundSchedulerTests`. Optional media-fixture tests may return
early when their fixture environment is absent; no decoded-media or live UI
qualification is implied.

## Evidence

Native measurements and integration results will be recorded here after the
research branch completes. Pull-request component runs use `--tests-only`;
the branch-push/manual workflow performs the full timing cohort.
