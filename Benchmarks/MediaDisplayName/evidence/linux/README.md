# Exact-#141 Linux qualification evidence

The [research report](../../../../Documentation/MEDIA_DISPLAY_NAME_PERFORMANCE.md)
explains the result, controls, historical-verifier repair, and native limitation.
This fresh cohort measures commit `c15703fcab7d7ccca3642eac626dad4923fb4fd9`, whose
production formatter is byte-identical to PR #141 at `5166cb73475b24dfb29f7115a5fa109e74379ba3`.
PR #233 adds qualification and has no production-source changes relative to #141.

- [Component summary](component-summary.json): all 11 label/recognition workloads.
- [Projection summary](projection-summary.json): all 10 surrounding row/control cases.
- [Component audit](component-audit.json) and [projection audit](projection-audit.json): independent reconciliation of every raw sample, source/log hash, output, and summary.
- [Receipt](receipt.json): identities, unchanged measured inputs, archive digest, and qualification status.
- [Raw archive](raw-results.tar.xz): complete retained records; its `raw-file-inventory.json` member lists per-file SHA-256 hashes.

The archive contains `component/` (four successful 47-test runs and all 220 final
observations), `projection/` (all 200 observations and complete traces), the failed
`historical-oracle/`, current-candidate `historical-diagnosis/` probes,
`component-audit/`, `projection-audit/`, source/environment/toolchain records,
portable CI log and result metadata, the old/new historical staging comparison,
and all invocation/console logs. `generate_report.py` derives the narrative tables
from this cohort. No failed historical check or calibration sample contributes to
final timing summaries. No final timing sample was removed.

Earlier independent-variant results remain at immutable commit
[`46f5384`](https://github.com/Jagalite/illiquid/tree/46f5384474e08bd04d6b20b5ab7a13adacdb01bf/Benchmarks/MediaDisplayName/evidence/linux).
They are not pooled into this cohort. The prior sandbox runtime failure/retry and
setup mistakes belong to that earlier record; this fresh focused qualification
started outside the sandbox and passed all four test invocations directly.

Compiled products and caches are omitted. Their hashes, exact source bytes,
compiler commands, logs, full outputs, and raw timings remain. Verify the archive
digest in `receipt.json`, extract to a fresh directory, and verify members against
its `raw-file-inventory.json` before analysis.

Portable GitHub correctness passed on the measured code. Native macOS
measurements, the intact historical oracle, and the native application build/tests
remain pending. Linux records are not native or live-player qualification.
