# Fuzzy subtitle scoring allocation research

## Question

Does borrowing the shared token prefix reduce the cost of fuzzy external-subtitle association while preserving its existing scores and output mappings?

The production matcher previously materialized `Array(mediaTokens.prefix(sharedCount))` for every fuzzy candidate. Swift may reuse backing storage when converting a full-buffer slice, so an array conversion does not by itself establish that an allocation occurred. The descendant fixtures exercise strict prefixes; the ancestor fixture is directional coverage and a control for a prefix that spans the media token buffer. The candidate passes the prefix directly to the existing generic `tokenWeight` function. It changes no tokenization, qualifier stripping, scoring constants, candidate traversal, cancellation checkpoints, ambiguity handling, or output ordering.

## Scope and fixtures

The benchmark compiles the complete production `ExternalSubtitleMatcher.swift`, `MediaFileSupport.swift`, and `NaturalFilenameOrdering.swift` as a separate optimized module. Baseline files come byte for byte from commit `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`; candidate files come from the current checkout. There are no platform stubs, copied matching algorithms, or external package dependencies.

Ten fixtures cover:

- Three ambiguous-prefix inventories with 16, 256, and 1,024 media files. Eight distinct language sidecars share the media prefix. Every candidate is a fuzzy descendant with an equal score, so all sidecars remain unassigned.
- Two longer-prefix inventories with 256 and 1,024 files, exercising larger temporary token arrays.
- One 256-file inventory whose uniquely shorter descendant wins on the existing unmatched-token penalty.
- One 256-file inventory with unique fuzzy ancestor matches: each sidecar adds `Directors Commentary` after its media stem.
- One 256-file Unicode-prefix inventory, retaining Foundation normalization and grapheme-count behavior.
- Exact-match and unrelated-name controls with 256 media files. These do not enter the modified fuzzy scoring branch.

Every filename component is at most 255 UTF-8 bytes. The eight language sidecars are distinct supported filenames. Their input order is reversed to exercise production sorting. Inputs are synthetic component workloads; their sizes and collision patterns are not inferred from a user's library.

## Correctness and measurement

The runner executes the five existing matcher, empty-input, tokenization, qualifier-storage, and candidate-traversal suites for both baseline and candidate, in debug and release. These are the actual repository tests. Before measurements, the driver verifies complete output dictionaries against independently specified fixture expectations, serializes every mapping, and compares the full baseline and candidate outputs. Each timed process also performs an untimed oracle check and validates its result-count checksum.

One timed iteration is a complete public `associate` call, result-count consumption, and result destruction. Fixture construction, URL serialization, and full mapping comparison are outside the timed interval. The matcher is compiled separately from the driver, and the measured loop is not inlined. Both monotonic wall time and process CPU time are recorded.

Each observation starts a fresh process and performs four warmup associations. A baseline and candidate pilot determine a shared iteration count targeting at least 250 ms of CPU time for the faster pilot, with a minimum of five associations. Six pairs alternate baseline/candidate and candidate/baseline order. Both implementations use deterministic Swift hashing, the same compiler, build flags, driver, and fixtures. Summary statistics retain all observations and report baseline/candidate ranges plus paired percentage-change ranges. Timing percentages are observations, not correctness thresholds.

The manifest records source and binary hashes, compiler/platform details, revisions, worktree status, test outcomes, and the exact measured cases. Raw observations, calibrations, complete mapping outputs, and command/test logs remain in the output directory. Before summarizing, the runner reloads the retained observations, checks equality with measured rows, and verifies the complete unique case/variant/pair grid. The reported metrics are wall and process CPU time; allocation counts and transient or retained memory bytes are not measured. This study measures subtitle association only; it does not establish an improvement in decoding, frame rate, or whole-player responsiveness.

## Reproduction

Swift 6.1 or newer is required. From a checkout containing the baseline commit:

```sh
python3 Benchmarks/SubtitleFuzzyScoring/run.py \
  --output /tmp/illiquid-subtitle-fuzzy-scoring \
  --pairs 6 --target-ms 250
```

Use a new or empty output directory. For correctness checks alone:

```sh
python3 Benchmarks/SubtitleFuzzyScoring/run.py \
  --tests-only --output /tmp/illiquid-subtitle-fuzzy-tests
```

A later cohort can reuse verified binaries without rebuilding:

```sh
python3 Benchmarks/SubtitleFuzzyScoring/run.py \
  --skip-tests --reuse-builds-from /tmp/illiquid-subtitle-fuzzy-scoring \
  --output /tmp/illiquid-subtitle-fuzzy-confirmation
```

Use `--cases long_1024,winner_256,exact_256 --pairs 2 --target-ms 100` for a bounded exploratory cohort. Full-output verification still covers all ten fixtures. Exploratory measurements should be identified separately from the final six-pair cohort.

When the shared Kyoto queue is available, submit the intended Python command through it as required by `AGENTS.md`. On an isolated runner without Kyoto, explain that limitation and run the package builds serially.
