# Media filename recognition performance

This investigation measures `MediaNameRecognition.recognize(relativePath:)`,
which supplies filename evidence while the source browser organizes media.
The candidate skips metadata/tag regular-expression work when the necessary
ASCII opening delimiter is absent. Inputs containing that delimiter retain the
original Foundation expression, including malformed tags and matches spanning
the joined filename/ancestor evidence.

The baseline is the complete production file from main at
`68274d1b09dcc866296321a5a8858efc297c4f19`. Its retained copy and Git blob/SHA-256
identities are in `baseline/`. Both variants build as separate `IlliquidCore`
modules from their complete source files; the driver does not reimplement the
recognizer. No regular expressions or recognition precedence are changed.

## Reproduce

Use Python 3.10+ and Swift 6.1+ with its bundled Testing library. The native
workflow uses macOS 26 and Xcode 26.6. The isolated packages have no external
package dependencies and require only Foundation; the full app has additional
macOS/native dependencies.

```sh
python3 Benchmarks/MediaNameRecognition/run.py \
  --pairs 8 --target-ms 750 \
  --output /tmp/illiquid-media-name-results

# Only the baseline/candidate debug and release regression suites:
python3 Benchmarks/MediaNameRecognition/run.py \
  --tests-only --output /tmp/illiquid-media-name-tests
```

Use a new or empty output directory. Do not run competing benchmark workloads
at the same time. The runner records every completed measured process, all
excluded calibration processes, source and executable hashes, commands,
compiler/host details, complete regression logs, and complete differential
outputs in compressed JSON archives. It stops on any correctness or identity
mismatch; there is no noisy wall-time threshold in CI.

## Method

- Run the original recognition tests and new boundary regressions against both
  variants in debug and release, with warnings treated as errors.
- Compare every stored and derived result field for a deterministic corpus
  containing all timed workloads plus adversarial filename/ancestor inputs.
  Optional values are compared explicitly, as are ordered catalog IDs and
  metadata sources. Preserve Unicode, malformed/nested tags, and the existing
  cross-component edition behavior.
- Build the same optimized benchmark driver against each complete production
  source. Generate fixtures and validate their semantic checksum before timing.
  Warm the recognizer before each timed sample.
- Use one calibration process per variant/workload to select an equal batch
  count for both variants. Calibration is retained and excluded from summaries.
- Take eight fresh-process pairs per case, alternate baseline/candidate order,
  and rotate case order per pair. Record all observations without outlier
  deletion, subtraction, or selecting favorable reruns.
- Record both process CPU time (`CLOCK_PROCESS_CPUTIME_ID`) and elapsed time
  (`DispatchTime.uptimeNanoseconds`). Report nanoseconds per filename, absolute median/range for each variant,
  reduction from those medians, median/range of paired percentage reductions,
  and the number of pairs in which the candidate was faster.

## Scope

These are warmed, in-memory recognition measurements including bounded batch
result handling. They exclude directory enumeration, sidecar I/O, row
construction, SwiftUI layout, media decoding, frame presentation, energy, and
end-to-end library latency. Corpus categories are synthetic workloads, not a
measurement of the user's library distribution. Untagged and tagged controls
are reported separately because the latter still execute the original regex
work and incur the added delimiter check. No memory-footprint claim is made.

The new workflow runs the focused tests, whole-output differential, and timing
on macOS. Existing repository workflows provide broader native integration
checks when the pull request is opened.

## Initial observations and measurement follow-up

The first native run used six pairs with a 150 ms target and elapsed timing
only. Both variants passed all 17 test functions in debug and release, and all
7,497 complete differential outputs agreed. It produced 144 timed processes.
The median paired elapsed reductions were 19.8% for plain movie names, 15.8%
for named episodes, and 10.9% for the mixed corpus. However, unclassified names
were 5.5% slower and malformed-tag inputs were 8.4% slower. Pair ranges were
wide, including a 49% slowdown in one malformed-tag pair. These observations
are insufficient to dismiss a regression as scheduling noise.

Before opening a PR, the measurement protocol was extended to record process
CPU time alongside elapsed time and to use eight pairs targeting 750 ms each.
The production candidate, baseline, input corpus, correctness checks, warmup,
and recognition loop remain unchanged. Every initial observation is retained;
the follow-up covers all 12 workloads and does not discard or replace the
initial cohort. Its purpose is to distinguish extra recognition work from
elapsed-time interference and to assess the two unfavorable controls.

Initial native workflow: [39069913567](https://github.com/Jagalite/illiquid/actions/runs/39069913567),
implementation commit `2c2e73cead0eb2843ada0a89451ac411b210fdcc`.
Final measurements will be recorded after the follow-up completes.
