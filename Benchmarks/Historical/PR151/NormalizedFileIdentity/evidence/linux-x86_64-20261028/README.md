# Portable file-identity evidence — 2026-10-28

This is Linux secondary evidence. Native macOS qualification is pending.
See the [study report](../../README.md) for results, scope, and tradeoffs.

- [manifest.json](manifest.json): measured revisions, environment, flags, and source/test/binary hashes.
- [correctness.json](correctness.json): four test passes and exact full-output parity.
- [completion.json](completion.json): successful completion and 180 retained observations.
- [cases.json](cases.json): workload definitions and sizes.
- [calibrations.json](calibrations.json): all calibration observations.
- [observations.jsonl](observations.jsonl): all 180 timed observations, without filtering.
- [summary.json](summary.json): medians, ranges, paired ratios, and time changes.
- [commands.json](commands.json): all recorded commands, timestamps, and successful exit codes.
- [portable-context.json](portable-context.json): probe-only workflow and fixture context.
- [receipt.json](receipt.json): run/artifact provenance, audit result, and log-tail metadata.
- `test-log-tails/`: the last 20,000 characters of each test log, including its final 70-test success summary. These are explicitly truncated tails, not full logs.

[Full CI run](https://github.com/Jagalite/illiquid/actions/runs/40637671688) and
[artifact](https://github.com/Jagalite/illiquid/actions/runs/40637671688/artifacts/12794093168)
retain complete test/build/verification/measurement logs and exact source
snapshots. The artifact has 14-day retention; the raw measurements and compact
receipts in this directory remain in Git.

The artifact SHA-256 is
`ce63fbb0055bbadb0d799495c5b0b3e44e922adbe464c8fe2d2c8a2d096e9258`.
