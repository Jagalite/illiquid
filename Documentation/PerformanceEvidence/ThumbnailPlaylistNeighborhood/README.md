# Thumbnail playlist neighborhood evidence

Measured implementation: [`2d066cacc8d8fc844dcaf6008cfdaeda61b69010`](https://github.com/Jagalite/illiquid/commit/2d066cacc8d8fc844dcaf6008cfdaeda61b69010).

[Native component job](https://github.com/Jagalite/illiquid/actions/runs/40634599986/job/122638536177)
completed successfully. The files here preserve its structured log records:

- `measurements.jsonl`: all 304 retained observations.
- `calibrations.jsonl`: all 119 calibration observations.
- `summary.json`: all 19 wall/CPU summaries, including controls and ranges.
- `qualification.json`: source and binary hashes, host/compiler metadata,
  four test results, 40-case parity receipt, artifact identity/digest, and
  independent arithmetic checks.

The [research report](../../THUMBNAIL_PLAYLIST_NEIGHBORHOOD_PERFORMANCE.md)
explains scope, source adaptation, the small-input regression, and the nine
short timing observations. The original artifact includes full output traces,
compiled binaries, source snapshots, and command logs. The committed numerical
records remain usable independently of the artifact's retention period.
