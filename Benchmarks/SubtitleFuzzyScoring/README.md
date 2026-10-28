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

Each observation starts a fresh process and performs four warmup associations. A baseline and candidate pilot determine a shared iteration count targeting 250 ms of CPU time for the faster pilot, with a minimum of five associations. Six pairs alternate baseline/candidate and candidate/baseline order. Both implementations use deterministic Swift hashing, the same compiler, build flags, driver, and fixtures. Summary statistics retain all observations and report baseline/candidate ranges plus paired percentage-change ranges. Timing percentages are observations, not correctness thresholds.

The manifest records source and binary hashes, compiler/platform details, revisions, worktree status, test outcomes, and the exact measured cases. Raw observations, calibrations, complete mapping outputs, and command/test logs remain in the output directory. Before summarizing, the runner reloads the retained observations, checks equality with measured rows, and verifies the complete unique case/variant/pair grid. The reported metrics are wall and process CPU time; allocation counts and transient or retained memory bytes are not measured. This study measures subtitle association only; it does not establish an improvement in decoding, frame rate, or whole-player responsiveness.

## Initial native results

The [initial macOS run](https://github.com/Jagalite/illiquid/actions/runs/40634076015)
passed on macOS 26.6.2 arm64 with Apple Swift 6.3.3. Baseline
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72` and candidate
`0187585a4193ccba412bb745d52759ace4409e1a` used identical harnesses,
supporting sources, and tests. The only production source difference is the
shared-prefix array conversion. Source and binary receipts are retained in
[evidence/macos-initial](evidence/macos-initial).

All 43 tests in five suites passed for both implementations in debug and release.
All ten complete fixture mappings matched their independent expectations and
each other. The retained 120 timing rows passed the complete-grid and hash checks.

The following percentages are medians of six **paired** candidate/baseline
changes; negative values mean less time. They are not ratios of independently
computed timing medians.

| Fixture | Paired CPU change | Candidate faster CPU pairs | Paired wall change |
| --- | ---: | ---: | ---: |
| `ambiguous_16` | -9.04% | 5/6 | -7.94% |
| `ambiguous_256` | -13.78% | 6/6 | -13.45% |
| `ambiguous_1024` | -10.78% | 5/6 | -10.42% |
| `long_256` | -17.72% | 6/6 | -17.89% |
| `long_1024` | -16.32% | 6/6 | -16.98% |
| `winner_256` | -15.80% | 6/6 | -17.54% |
| `ancestor_256` | -2.44% | 3/6 | -3.45% |
| `unicode_256` | -8.10% | 5/6 | -11.68% |
| `exact_256` | -2.91% | 4/6 | +19.41% |
| `unrelated_256` | -2.92% | 3/6 | -7.82% |

The long-prefix and unique-winner cases were faster in all six CPU pairs.
The exact-match control had a +19.41% median paired wall-time change despite
a -2.91% CPU change and overlapping CPU ranges. These initial observations alone
do not establish an absence of wall-time regressions. A focused follow-up uses
longer samples for `long_256`, `winner_256`, `exact_256`, and
`unrelated_256`, plus an identical-baseline-binary exact-match control, to
investigate that uncertainty. Both cohorts will be retained.

The 250 ms setting is a calibration target, not a guaranteed sample duration:
the initial CPU samples ranged from 158.36 to 387.28 ms. Allocation counts and
memory usage were not measured. No whole-player or playback-frame-rate claim is made.

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
