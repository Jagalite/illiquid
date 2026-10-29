# Manual source visibility performance

This study measures source-browser projection when visibility is controlled by
manual hidden paths or always-show paths and there are no compiled regex rules.
The production change defers relative-path construction and skips regex range
preparation in that case. Active regex evaluation and ancestor traversal keep
their existing behavior.

## Reproduce

### Native macOS qualification

Use macOS with Swift 6.1 or newer. The runner builds an offline component package
from the actual production declarations; it does not require FFmpeg or libass.
Run builds through the shared Kyoto queue when available, as required by
[AGENTS.md](../../AGENTS.md). On a host without Kyoto:

```sh
python3 Benchmarks/ManualVisibility/run.py \
  --output /tmp/illiquid-manual-visibility \
  --pairs 8 --sizes 100,1000,10000 --target-ms 80
```

The output directory must be new or empty. `--cases` accepts comma-separated
case names below. Without `--tests-only`, both runners retain the strict
historical performance comparison and reject unrelated production changes.

### Current-source regressions

Use `--tests-only` with either runner to run all six suites in debug and release
against current production and a behavioral reference. The reference inserts the
verbatim matcher from the pinned revision into the current extracted sidebar;
all surrounding declarations and supporting files are current and identical in
both variants. This adapted reference is **not the original performance baseline**.
The manifest labels it `reference`, records the historical matcher/source hashes
and current source receipts, sets `baseline` to null, and reports zero timing pairs.

All 13 diagnostic workloads and negative controls still compare both variants at
1, 31, and 257 entries with identical receipt and cache-rebuild checks. No timing
observations or performance summaries are produced. Push and pull-request jobs
use this mode. Manual `workflow_dispatch` retains strict historical performance
mode and must reject incompatible current sources. Frozen evidence is unchanged.

### Portable Linux qualification

A separate runner reuses the native study's tests, harness, pairing, timing and
output checks. Linux needs Swift 6.1 or newer on PATH:

```sh
python3 Benchmarks/ManualVisibilityPortable/run.py \
  --output /tmp/illiquid-manual-visibility-portable \
  --pairs 8 --sizes 100,1000,10000 --target-ms 80
```

The wrapper applies exactly three guarded compatibility changes to both
variants: `Darwin` becomes `Glibc` in the sidecar reader; the NFO parser imports
`FoundationXML`; and one existing sidecar test fixture supplies its temporary
directory's explicit `isDirectory: true` hint. Production matcher and projection
code are unchanged by these adaptations. The manifest records original and
compiled hashes and rejects unequal adaptations.

Portable results qualify Linux component behavior and latency. Keep them
separate from native macOS results; they do not establish the performance of
macOS Foundation or the app's displayed UI.

## Comparison and timing boundary

- Baseline: `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`.
- The runner reuses the guarded extractor from
  [SourceTreeVisibility](../SourceTreeVisibility/run.py). Production declarations
  are copied verbatim by the native runner. The portable wrapper applies only
  the three symmetric adaptations documented above.
- Every supporting production file must match between baseline and candidate.
  The only allowed focal difference is within `SourceVisibilityMatcher`.
- Both variants receive the same harness and regression test sources. All
  source, harness, and binary hashes are recorded.
- Each duration surrounds one awaited production
  `SourceBrowserFilter.project(input:revealsRulePreview:query:)` call.
- The raw tree is warm. Configurations or preview state alternate so that each
  call rebuilds visibility. Diagnostic and timed runs assert exactly one raw
  tree build and one visibility build per call. Timed-run counters are read
  after all measured calls.
- Synthetic fixtures use one lexical local root, flat entries or two directory
  levels, and prepopulated media recognition. Fixture construction, compilation,
  process startup, warmups, output hashing, and filesystem I/O are excluded.
- Eight fresh-process pairs use balanced AB/BA order. The same even iteration
  count is calibrated from the faster variant toward 80 ms of measured work per
  member, capped at 1,024 iterations. This is a calibration target, not a
  guaranteed sample duration; inspect the retained elapsed times.
- Each sample is a process mean. Summaries report the median paired
  baseline/candidate ratio, all individual ratios, and absolute median times.
  Timing values are observations, not CI pass/fail thresholds.

## Workloads

| Case | Visibility workload |
| --- | --- |
| `tree_manual` | Alternate two sets of manually hidden files |
| `tree_manual_ascii` | The same workload with an ASCII-only root path |
| `tree_preview` | Toggle preview of manually hidden files |
| `tree_always_show` | Alternate always-show sets without regex rules |
| `tree_disabled_manual` | Manual hiding with a disabled regex rule |
| `tree_invalid` | Enabled invalid regex; no successfully compiled rules |
| `tree_nested_manual` | Expanded tree with hidden files and ancestor folders |
| `files_nested_manual` | Recursive Files view with hidden files and ancestors |
| `media_nested_manual` | Recursive Media view, including media grouping |
| `tree_default_control` | Default settings; per-row matcher already bypassed |
| `tree_disabled_control` | Disabled regex only; per-row matcher already bypassed |
| `tree_regex_control` | Active regex with flat entries |
| `files_nested_regex_control` | Active regex with recursive ancestor matching |

## Correctness and retained evidence

The same six suites run against both variants in debug and release in both modes. The new
matcher suite covers manual precedence, hidden roots and ancestors, always-show
overrides, invalid/disabled rules, active match ordering, Unicode paths,
overlapping roots, preview annotations, and raw-tree reuse.

Differential runs use 1, 31, and 257 media entries for every case. Receipts
include ordered row fields, visibility annotations, recognized metadata, rule
counts, hidden counts, thumbnail order, and media-path membership. A stable
checksum covers every row field; the full counts and receipt cycle are compared
between variants and again for all timed samples.

`manifest.json` records provenance, source and binary hashes, host, compiler,
and timing boundaries. `verification.json`, `tests.json`, `calibrations.json`,
`measurements.jsonl`, and `summary.json` retain the behavioral checks and raw
observations. CI also uploads the compiler/test logs and staged Swift sources.

See [the research report](../../Documentation/MANUAL_VISIBILITY_PERFORMANCE.md)
for measured results and qualification links.

## Interpretation

The default no-rule browser already bypasses per-row visibility evaluation.
The intended benefit is visibility rebuilds with manual hiding or always-show
state. Query-only changes reuse cached visibility and are not an improvement
claim. These are component timings; they do not measure whole-window latency,
frame rate, playback CPU, energy, RSS, or peak allocations.

The comparison intentionally stops if unrelated supporting production sources
change. Review and explicitly refresh the comparison before reusing it against
a later incompatible snapshot.
