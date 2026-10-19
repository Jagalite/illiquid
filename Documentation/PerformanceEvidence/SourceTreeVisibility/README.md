# Source-tree visibility qualification evidence

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

Native macOS qualification is pending PR CI. See the
[research report](../../SOURCE_TREE_VISIBILITY_PERFORMANCE.md) and
[reproduction instructions](../../../Benchmarks/SourceTreeVisibility/README.md).
