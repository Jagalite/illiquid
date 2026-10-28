# Linux episode display-name evidence

The [research report](../../../../Documentation/MEDIA_DISPLAY_NAME_PERFORMANCE.md)
explains the measured result, controls, failures, and native qualification limit.

- [Component summary](component-summary.json): all 11 label/recognition workloads.
- [Projection summary](projection-summary.json): all 10 surrounding row/control cases.
- [Component audit](component-audit.json) and [projection audit](projection-audit.json): independent reconciliation of raw samples, hashes, outputs, and summaries.
- [Receipt](receipt.json): baseline/candidate identities, source checks, archive digest, and qualification status.
- [Raw archive](raw-results.tar.xz): every retained receipt, with its `raw-file-inventory.json` member recording per-file SHA-256 hashes.

The archive contains `component-final/` (the four successful test runs and complete
220-observation study), `projection/` (all 200 observations and complete traces),
original failed `component/` logs and successful identical-binary retry, the failed
`historical-oracle/` and isolated `historical-diagnosis/` Foundation probes,
`component-audit/`, `projection-audit/`, source/environment/toolchain records, and
invocation/console logs. An initial historical wrapper CLI error is also retained;
it produced no measurements. No failed attempt or calibration sample contributes
to the final summaries. No final timing sample was removed.

Compiled products and caches are omitted. Their hashes, source bytes, compiler
commands, process logs, full outputs, and all raw timings remain. Verify the
archive digest from `receipt.json`, extract to a fresh directory, then verify
members against `raw-file-inventory.json` before analysis.

Native macOS measurements, the intact historical oracle, and the full native
application build/tests were pending at publication. These Linux records are not
native or live-player qualification.
