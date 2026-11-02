# Sidebar reload-selection performance

## Change and scope

`SourceTreeDirectoryState.reloadPaths` decides which directories to reload after
`SourcesSidebar.applyFilesystemEvents` invalidates cached directory state. It
runs on the main actor. The baseline builds normalized active-root identities,
then normalizes the same root URLs again while checking every affected path.

The candidate reuses the existing local set of normalized roots. It accepts an
active root immediately, checks ancestry only for expanded descendants, and
returns early when either the active roots or reload/rescan candidates are empty.
There is no retained cache or new invalidation policy. Both URL normalization and
component-boundary containment still use the existing `SourceTreeIdentity`
helpers. Plan paths and expansion IDs are not normalized again.

For `R` roots, `P` affected paths, and `E` expanded nonroot paths, repeated URL
normalization falls from up to `R + P × R` calls to `R`. Containment still has a
worst case of `E × R` string comparisons. The normalized-root set already existed
in the baseline; this change does not add persistent memory.

The retained baseline is the complete production file at
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`. Its SHA-256 is pinned in
[`baseline/manifest.json`](baseline/manifest.json).

## Correctness

Let `M` mean the affected path is an active root, `E` mean it is expanded, and `C`
mean it is contained in an active root. The old predicate is `C && (M || E)`.
Since an active root contains itself, `M` implies `C`, so `M || (E && C)` is
equivalent. Root normalization is pure, and an empty candidate union or empty
active-root list already selected no paths.

The differential verifier compares sorted arrays of UTF-8 bytes for **5,054
fixtures**, including the timed workloads. It covers filesystem root `/`, prefix
siblings, overlapping and duplicate roots, URL aliases, unsupported-URL fallback
paths, empty paths, composed/decomposed Unicode, raw dotted paths, and overlapping
reload/rescan sets. It checks that invalidated trees alone do not become reloads.

The repository's actual-source directory-consumer harness additionally compiles
the complete consumer and planner with the existing browser support and tests.
The new expected-result tests cover the same semantic boundaries independently
of the old implementation.

## Executed Linux evidence

The initial Ubuntu 24.04 x86_64 / Swift 6.3.2 campaign completed all 5,054 exact
comparisons and 168 timed observations: six balanced pairs for each of 14
workloads. The complete actual-source component suite passed **24 tests in two
suites** in both debug and release. The first debug build failed inside the
process sandbox before any tests ran; its receipt is retained as excluded
environment evidence. Both successful test builds and the benchmark then ran
outside that process sandbox. Kyoto was unavailable.

Selected wall-time results (microseconds per complete selection call):

| Workload | Baseline median | Candidate median | Median paired reduction |
| --- | ---: | ---: | ---: |
| One expanded folder, one root | 7.51 | 6.13 | 18.3% |
| 64 mixed paths, one root | 266.95 | 12.33 | 95.2% |
| 512 mixed paths, eight roots | 11,758.49 | 208.56 | 98.4% |
| 512 expanded paths, eight roots | 10,303.74 | 273.97 | 96.9% |
| 4,096 collapsed paths, eight roots | 68,705.32 | 551.77 | 99.1% |
| 512 Unicode paths, eight roots | 18,871.51 | 997.80 | 94.6% |

The reported paired reductions are medians of paired ratios, so they need not
equal the ratio of the independently calculated medians. The empty-plan and
no-active-root controls reach the early return in roughly 8 ns/call, but their
candidate sample intervals remain below 1 ms after the calibration cap; no
precise speedup is claimed for those controls. Every other workload has no
sub-millisecond timed samples in this campaign. The smallest single-folder
results are more sensitive to noise than the batch results.

Raw [wall and CPU results](evidence/linux/results.json),
[all observations](evidence/linux/measurements.jsonl),
[calibration](evidence/linux/calibration.json),
[source/toolchain manifest](evidence/linux/manifest.json),
[exact-output receipt](evidence/linux/equivalence.json), and
[debug](evidence/linux/tests-debug/receipt.json) /
[release](evidence/linux/tests-release/receipt.json) test receipts are retained.
These are Linux component results; native macOS confirmation is still required.

## Reproduce

Use Swift 6.1 or newer with its bundled Testing module. No media fixtures,
filesystem enumeration, native playback SDK, or network dependencies are needed.
The benchmark supports Linux and macOS; native Foundation results are required
before drawing conclusions about macOS performance.

Follow `AGENTS.md`: submit builds through Kyoto when available. On an isolated
host without Kyoto, record that limitation before direct builds. Keep compilation
sharing a build directory serialized.

```sh
python3 Scripts/test-source-tree-directory-state.py \
  --configuration debug --output /tmp/reload-selection-tests-debug
python3 Scripts/test-source-tree-directory-state.py \
  --configuration release --output /tmp/reload-selection-tests-release
python3 Benchmarks/SourceReloadSelection/run.py \
  --output /tmp/reload-selection-results --rounds 8 --target-ms 250
```

Each output directory must be new or empty. `--verify-only` skips timings;
`--workloads NAME ...` selects timings while retaining the complete differential
corpus. `--iterations N` overrides automatic calibration for a confirmation run.

## Measurement method

The runner extracts the exact selector method into an actor-isolated enum and
the exact `SourceTreeIdentity` and `SourceFilesystemInvalidationPlan` declarations
from production. It copies `NormalizedFileURL.swift` completely. The baseline
and candidate method bodies are unchanged by this extraction. Full source and
slice hashes, compiler arguments, toolchain, CPU, and binary hashes are recorded.

The harness and selector are compiled as separate optimized modules. An exported
`@inline(never)` adapter prevents the harness from specializing or eliminating
the repeated selector calls. Each timed call constructs the plan value, runs the
complete selector including root normalization, union, filtering, and result-set
construction, then consumes the result count. Input construction, eight warmup
calls, exact-byte verification, and JSON serialization are outside the timer.

Fresh processes alternate baseline/candidate and candidate/baseline order for an
even number of pairs. Both members of each pair use the same iteration count.
Calibration first targets the baseline duration, then increases iterations when
needed to target at least 5 ms of candidate work, subject to an estimated 2-second
baseline cap and a 10-million-iteration cap. All pilots, raw wall/process-CPU
durations, paired changes, and short-duration flags are retained. No timing
outliers are removed. Controls whose candidate duration remains below 1 ms should
not be used to claim a precise percentage improvement.

The workloads use 1, 8, or 32 roots and 1, 64, 512, or 4,096 affected paths, with
expanded, collapsed, inactive, overlapping, and Unicode cases. The 4,096-path
case is a burst stress case, matching the event buffer's nominal detail bound;
it is not a claim about typical user workloads. Empty-plan, no-active-root, and
root-rescan controls include setup costs and early-return behavior.

## Limits

These are synthetic in-memory component measurements. They exclude event
delivery, cache invalidation, directory I/O, row rebuilding, rendering, and live
UI interaction. They establish neither whole-player CPU reduction nor improved
playback frame rate, battery use, or end-to-end sidebar latency. Root-set iteration
order is unspecified; timings include normal per-process Swift hash seeding.

The path-filtered macOS workflow runs the same differential and paired timing
campaign. The existing Source volume regressions workflow runs full directory
consumer and volume-routing tests in debug and release.
