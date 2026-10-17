# Playlist identity lookup evidence

The native campaigns are preserved as the original GitHub Actions artifact
ZIPs, with readable summaries and audit receipts. [runs.json](runs.json) records
the exact implementation commit, workflow, artifact and archive SHA-256 for each
campaign.

## Final candidate

- [Successful native workflow](https://github.com/Jagalite/illiquid/actions/runs/39071134091)
- [Complete original artifact](final-macos.zip)
- [All 29 workload summaries and test results](final-macos-summary.json)
- [Evidence-integrity audit](final-macos-audit.txt)

This campaign measures the mutation-only implementation at
`08bdeba66d2d440ea83bbe324f0e296a65480071`. Folder lookup source is identical
to the baseline. Empty/singleton mutation measurements use the declared
500,000-iteration minimum. This is the source of the final report's performance
claims.

## Initial candidate

- [Successful native workflow](https://github.com/Jagalite/illiquid/actions/runs/39070214459)
- [Complete original artifact](initial-macos.zip)
- [All 29 workload summaries and test results](initial-macos-summary.json)
- [Evidence-integrity audit](initial-macos-audit.txt)

This campaign changed both playlist lookup functions. It is exploratory evidence
for the subsequent mutation-only refinement. It did not use the final
empty/singleton shortcut or short-path iteration minimum. Its timings must not
be combined with the final candidate's measurements.

## Contents and verification

Each archive contains `manifest.json`, `summary.json`, `workloads.json`,
`observations.jsonl`, `commands.jsonl`, full command output under `logs/`,
and exact source/test/harness/runner snapshots under `sources/`. The `build/`
entries contain generated test-package sources, not compiled executables.
Driver and library hashes are recorded in the manifest. Calibration and
measurement rows are explicitly labeled; all completed observations are
retained.

The archives are byte-for-byte copies of the original uploaded artifacts.
Verify their SHA-256 against `runs.json` before extracting:

```sh
shasum -a 256 initial-macos.zip final-macos.zip
```

The post-run audit recomputed every median and paired reduction from raw rows,
checked balanced pair positions, result/iteration receipts, complete unique
workload coverage, successful command/log records, and source SHA-256 values
against the recorded Git commits. A separate reviewer checked the final
production source, experiment design, complete CI log, command structure, and
reported results. These are evidence and correctness reviews, not another
independent performance experiment.

The [research report](../../PLAYLIST_IDENTITY_LOOKUP_PERFORMANCE.md) explains
results, negative controls, and limits. The
[runner instructions](../../../Benchmarks/PlaylistIdentityLookup/README.md)
provide reproduction steps.
