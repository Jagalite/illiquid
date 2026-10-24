# External-subtitle filename tokenization

This experiment measures complete `ExternalSubtitleMatcher.associate` calls
over prepared folder inventories. The optimization handles ASCII filename stems
with contiguous UTF-8 storage using byte-level case conversion and token splitting. Non-ASCII filenames and
strings without contiguous UTF-8 storage retain the existing Foundation
normalization path. The trie, matching scores, ambiguity handling, cancellation, and natural subtitle ordering are unchanged.

## Reproduce

Use Swift 6.1 or later (both `swift` and `swiftc` on `PATH` from the same
toolchain) and Python 3.9 or later:

```sh
python3 Benchmarks/SubtitleTokenization/run.py \
  --output /tmp/illiquid-subtitle-tokenization --pairs 6
```

The output directory must be empty. `--mode tests` runs only correctness tests;
`--mode benchmark` runs full association parity checks and paired measurements.
`--case NAME` can be repeated to time selected workloads; full association
verification still runs for all fixtures. The isolated package has no downloaded
dependencies. The macOS workflow follows the repository's macOS 26 / Xcode 26.6 component qualification setup.

## Method

The baseline is the complete production matcher and its two dependencies at
`a2de305c8dbcaa81aac1477df7c9a0017c14eae3`. The runner verifies each frozen file's
Git blob identity before compilation. Baseline and candidate are built into
separate optimized `IlliquidCore` libraries; the same driver links against each
with `-swift-version 6 -O -whole-module-optimization`.

Each timed iteration performs a complete association call, consumes its media
key count and total subtitle count, and releases the result. Fixture creation,
full output serialization, correctness checks, warmup, and JSON output are
outside the timer. No overhead is subtracted. Each pair uses identical iteration
counts, calibrated from baseline process CPU time toward a requested batch
duration. Defaults are 150 ms and six serial AB/BA pairs using fresh processes.
The native qualification workflow uses longer 500 ms targets and twelve pairs.
All observations are retained, including unfavorable samples. Both wall and process CPU measurements are reported.

The workload matrix includes small movie/season inventories, large folders,
three subtitle languages per media file, longer release names, unrelated and
ambiguous subtitle names, mixed and entirely Unicode names, a non-ASCII character
late in a long stem, and empty/unsupported subtitle controls. The driver checks
full URL-to-ordered-subtitle mappings between baseline and candidate before
timing, in addition to independent fixture expectations. Timed count checksums
guard against dropped work; they are not the full correctness oracle.

## Correctness and retained evidence

In the default `--mode all` and in `--mode tests`, the runner executes the
existing matcher/empty-inventory suites plus the new tokenization regressions
against both implementations in debug and release. `--mode benchmark` performs
association verification and timing without those test configurations.
The new regressions compare normalization behavior with Foundation and check
Unicode fallback and association semantics. Existing tests cover cancellation
at every observed checkpoint, exact/prefix matches, language suffixes, release
qualifiers, duplicate inputs, ambiguity, and natural ordering.

Output includes source snapshots and hashes, test logs, exact association
outputs, command receipts, calibration, raw timings, and summaries. The workflow
packages the complete directory as an artifact and prints its SHA-256.

These are component measurements with synthetic filenames. They do not measure
filesystem I/O, full folder-open latency, rendering, playback CPU, or battery
life. Performance numbers are reported evidence, not a noisy CI pass/fail gate.

## Research acceptance criteria

Before measurements, the proposed acceptance criteria are identical full
association outputs and passing regressions in both builds, at least a 10%
median process-CPU reduction in the 16- and 256-file ASCII cases with at least
five of six pairs faster, and no repeatable regression above 5% in the Unicode
or empty-input controls. An apparent control regression warrants a focused
confirmation; it is not a reason to discard individual unfavorable samples.
The native macOS run determines the platform-specific performance claim.
For the twelve-pair refinement qualification, the direction check scales the
original five-of-six fraction to at least ten faster pairs. See [RESULTS.md](RESULTS.md) for the measured cohorts,
source revisions, full results, limitations, and retained evidence.
