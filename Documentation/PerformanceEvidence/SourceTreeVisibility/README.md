# Source-tree visibility qualification evidence

## Completed macOS qualification

`macos/` retains the completed native qualification from October 19, 2026.
Both variants passed all three component suites in debug and release, and all
30 workload/size cells completed six balanced pairs: 360 process observations,
4,992 timed projection calls, and 60 separate diagnostic observations.

The baseline is `33fff16155c3472960f88e04c72dfdfdefd56dcf`. The measured PR
head is `833c79a2d2e2ca675990c1009f0f7891f29c3bb0`; GitHub checked out merge
`d851a023d30a178bec587458a44415ba68ffbc88`, which has the identical tree.
The environment was macOS 26.6.2 arm64 with Apple Swift 6.3.3, using the
workflow's selected Xcode 26.6.

- `qualification.zip` is the exact artifact from
  [job 118301206085](https://github.com/Jagalite/illiquid/actions/runs/39322896553/job/118301206085).
  Its 156,358 bytes have SHA-256
  `51c4cf57bbbda5a6e2bd3f6a4afeb371b6d6b7bf649e72a4dca86ef741046640`,
  matching the GitHub artifact digest. It includes the original observations,
  diagnostics, command/test logs, source manifests, runner, and staged sources.
- `summary.json` and `environment.json` are unchanged copies from that ZIP for
  convenient review.
- `qualification.json` records source identity, artifact member hashes, coverage,
  test results, the numerical review, and related integration checks.
- `independent-audit.json` records the separate source, result, and statistics
  audit, including the limits of binary verification from the compact artifact.

The native results are a separate cohort from Linux: the baseline shared sources,
compiler, platform, and benchmark module layout differ. The source cache change
itself is identical.

## Linux run

`linux/` retains the original text evidence from the 2026-10-17 20:23 UTC run
against baseline `68274d1b09dcc866296321a5a8858efc297c4f19`. The source manifests
identify the exact candidate by content hashes; the worktree was not committed
when this local run started. The exact original runner, retained baseline,
shared sources, tests, and candidate were subsequently committed at
`daa5ea76d0bb570783cc91c521f34790ed8e1539`. The two changed production files
remain identical after integration with the newer `main`.

The run passed both source variants' component tests in debug/release and the
expected baseline cache-count failure. It completed 29 six-pair workload/size
cells, including all 18 visibility-edit cells, before the candidate exited
with SIGILL during the final 10,000-file sort control. The unsymbolized dump
contains a `/proc/.../stat` path; the cause is unconfirmed. All 350 successful process
observations and the failed command's crash output are retained. The final
incomplete control is not included in any six-pair result.

- `qualification.json` records completion and the failed invocation.
- `reviewed-summary.json` was independently derived from the complete six-pair
  cells in `measurements.jsonl`; the interrupted runner did not emit its normal
  `summary.json`.
- `diagnostics.jsonl` records separate untimed cache-count checks for all cases.
- `commands.jsonl`, `tests.json`, and test logs retain the executed commands and
  their outcomes, including the deliberate baseline cache-count failure.
- `environment.json` records the compiler, platform, fixture scope, and driver
  hashes. The source manifests record production, staged source, test, and
  binary hashes.

The duplicate runner copy and compressed staged-source archive are omitted from
Git. The runner, tests, candidate source, retained baseline declarations, and
staging rules are retained in the original commit identified above; their exact
hashes remain in the manifests. CI artifacts additionally contain that compressed
archive. The current native runner uses a refreshed baseline at
`33fff16155c3472960f88e04c72dfdfdefd56dcf`, including the newer shared recognition
and sidecar code; this does not revise the historical Linux observations.

Earlier local setup attempts exposed two Linux-specific issues: the Swift
standalone driver intermittently trapped while inspecting a child thread, and
one existing sidecar fixture lacked an explicit directory URL hint before its
directory existed. The harness uses the integrated driver on Linux and applies
a guarded directory hint to that staged test only. Both variants then passed
all component tests in both build configurations. No macOS production source
or canonical test fixture was changed for these host accommodations.

## First macOS attempt

`macos-attempt-1/qualification.zip` is the exact downloaded artifact from job
118291027788 in run 39319927060. Its SHA-256 matches the GitHub artifact digest.
`qualification.json` records source identity, the successful debug tests, and
the baseline release test-loader failure. No benchmark timings were collected.
The correction separates the production library target from the executable
entry point; the production cache implementation is unchanged.

The corrected native run completed successfully. See the
[research report](../../SOURCE_TREE_VISIBILITY_PERFORMANCE.md) and
[reproduction instructions](../../../Benchmarks/SourceTreeVisibility/README.md).
