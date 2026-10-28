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

## Native results

The primary cohort is from [GitHub Actions run 40633988090](https://github.com/Jagalite/illiquid/actions/runs/40633988090),
component job 122636618142, at tested commit
`5095f4f03ef535ad194e10ac7de45b11e83739e4`.
The host was an **Apple M1 virtual machine**, macOS **26.6.2**, with
Apple Swift **6.3.3** through Xcode 26.6.

| Discovered files | Exclusions | Folder | Baseline median (ms) | Candidate median (ms) | Median paired reduction |
| ---: | ---: | :--- | ---: | ---: | ---: |
| 32 | 0 | nil | 0.128 | 0.073 | 45.96% |
| 32 | 0 | present | 0.159 | 0.138 | 1.67% |
| 32 | 16 | nil | 0.279 | 0.242 | 20.36% |
| 32 | 16 | present | 0.320 | 0.306 | 5.34% |
| 256 | 0 | nil | 0.981 | 0.348 | 59.19% |
| 256 | 0 | present | 1.097 | 1.063 | 1.71% |
| 256 | 16 | nil | 1.389 | 0.907 | 37.27% |
| 256 | 16 | present | 1.286 | 1.266 | 1.70% |
| 2,048 | 0 | nil | 7.017 | 1.850 | 72.17% |
| 2,048 | 0 | present | 6.376 | 5.270 | 1.97% |
| 2,048 | 16 | nil | 7.373 | 3.660 | 51.67% |
| 2,048 | 16 | present | 7.222 | 7.145 | -3.11% |

Time columns are separate per-variant medians. The percentage is the median
of eight within-pair reductions, so it need not equal the reduction calculated
from those two time medians. A negative percentage means the candidate was slower.

All **48 nil-folder pairs improved**, with positive medians in both AB and BA
order for every treatment workload. The largest no-exclusion case has a
**3.596x median paired speedup**; even its weakest pair improved by 59.35%.
The 32/256/2,048 discovery cases contain 106/426/2,218 candidate entries after
the scheduler's overlapping groups are combined.

The six folder-present controls have median paired changes from **3.11%
slower to 5.34% faster**. Their individual pairs are noisy, including an
isolated 118.36% slowdown retained in the raw evidence. There is no consistent
regression signal, but this hosted cohort cannot establish narrow percentage
equivalence for the unaffected path. Do not interpret the separate timing
medians in a noisy control as a reliable gain.

## Validation and retained evidence

- 4,218 ordered-output differential checks passed in **debug** and another
  4,218 in **release**, against the immediate current-main baseline.
- All 12 measured-workload ordered-output comparisons passed.
- The separate full-package release build succeeded in 507.83 seconds.
  Swift Testing reported **23 passing tests in three suites** in 18.379 seconds.
  Three optional media/render cases returned early because this workflow does
  not supply their fixture/image environment; they are listed in the
  [integration receipt](evidence/native-integration/receipt.json).
- All 302 recorded component commands exited successfully.
- All 192 timing observations are present, with adjacent pairs and four AB /
  four BA pairs for every case. Actual measured batches were at least 127 ms;
  all final calibration batches reached the requested 200 ms.
- An independent audit recomputed every summary, matched observations to
  command output, checked ordered-output hashes, and matched the measured
  candidate source to GitHub's exact source bytes.

The production candidate's Git blob is
`5568ecb0b11062aa917e1470cc88b35e335169d0`; its SHA-256 is
`e9a1e2c8183648e020f8c9faa0bbfb6a8d65cedff0e29dd86fce1b4555f3cd9f`.
Only workflow dependency path filters and research documentation/evidence were
updated after the measured commit; production and harness bytes are unchanged.

The [primary evidence](evidence/native/) includes the source/compiler/host
manifest, library linkage and binary receipts, command log, calibration,
complete ordered-output parity, raw observations, summaries, and completion
receipt. The full-package native integration [receipt and original job log](evidence/native-integration/)
record its successful outcome and qualification limits.

Pull-request component runs use `--tests-only`; branch-push/manual runs
perform the full timing cohort. The research result applies to this ranking
component and these synthetic scheduler inputs. Playback FPS, UI latency,
energy, and allocation changes were not measured.
