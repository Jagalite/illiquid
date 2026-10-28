# Source visibility regex preparation

## Question and change

Manual hide/show rules use normalized absolute paths. Before this experiment,
`SourceVisibilityMatcher` nevertheless prepared a root-relative regex candidate
and UTF-16 range for each evaluation, even when every regex was absent,
disabled, or invalid.

The candidate keeps that preparation in a nonescaping autoclosure and invokes
it only when at least one compiled regex exists. Root selection, URL
normalization, manual-rule precedence, ancestor traversal, match ordering, and
regex cancellation remain in their existing code paths.

The baseline is commit `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`.

## Reproduce on macOS

Use Swift/Xcode compatible with the repository. The qualification workflow uses
macOS 26 and Xcode 26.6.

```sh
python3 Benchmarks/SourceVisibilityRegexPreparation/run.py \
  --output /tmp/illiquid-visibility-regex-new \
  --pairs 10 --sizes 100 1000 10000 --target-ms 100
```

The output directory must be new or empty. Add `--tests-only` for correctness
qualification without measurements. The runner uses the shared Kyoto queue
when its documented path is available and explains the isolated direct-build
fallback otherwise.

## Method

The runner stages complete production files and guarded, verbatim declarations
using the existing source-tree benchmark extraction helper. It pins the
baseline and checks that the visibility matcher-containing declaration file is
the only changed production input. It builds the same driver separately from
the production module, with no external package dependencies.

Five regression suites run against baseline and candidate in both debug and
release. Complete projection JSON is compared before timing. Every measured
result is checked against that verified projection, including row ordering,
visibility annotations, hidden counts, rule counts, media paths, and thumbnail
candidates.

The workloads cover manual hide, always-show without regex, inherited manual
hiding in Files Only, disabled regex, invalid regex, enabled nonmatching regex,
enabled matching regex, and default visibility. Each runs at 100, 1,000, and
10,000 input rows.

For each workload, separate calibration processes choose equal iteration
counts for baseline/candidate. Ten fresh-process pairs alternate AB/BA order.
The driver times the complete awaited
`SourceBrowserFilter.project(rows:configuration:roots:revealsRulePreview:query:)`
call on a fresh actor. Fixtures and actor construction happen before the timer;
complete output consumption and receipts happen after it. Wall and process CPU
times are retained for every call. No timing observations are discarded.

The native integration job also compiles the application graph and runs the
focused visibility suites in release configuration.

## Scope

These are synthetic, native macOS visibility-projection measurements. They
exclude directory scanning, filesystem I/O, row construction, and UI rendering.
They measure visibility recomputation, not cached search-only updates, playback
throughput, or application frame time. Enabled-regex and default-visibility
workloads are controls; success depends on a repeatable reduction in manual-only
filtering without a material control regression.

## Evidence

The runner writes source and binary hashes, host/compiler identity, commands,
test results, complete verification receipts, calibration, every timing sample,
and paired summaries. CI uploads the full bundle and emits reviewable JSON in
its logs. Results from the research run will be recorded here after completion.
