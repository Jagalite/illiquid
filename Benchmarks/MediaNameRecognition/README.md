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
  --pairs 6 --target-ms 150 \
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
- Take six fresh-process pairs per case, alternate baseline/candidate order,
  and rotate case order per pair. Record all observations without outlier
  deletion, subtraction, or selecting favorable reruns.
- Report nanoseconds per filename, absolute median/range for each variant,
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

## Results

Native results will be recorded here after the research workflow completes.
