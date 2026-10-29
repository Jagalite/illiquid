# WebVTT NOTE experiment receipts

See [the report](../../../../Documentation/WEBVTT_NOTE_MEMORY_RESEARCH.md) for
interpretation and repeatable commands.

- `prototype`: all 96 observations from the initial unconditional prefix check,
  its full source snapshot, compiler/build manifest, and summary. This variant
  was replaced after its ordinary WebVTT control became slower.
- `final`: all 96 fresh-process observations from the gated implementation,
  exact baseline/candidate sources, fixture hashes, compiler/build manifest,
  driver and runner snapshots, and unfiltered summary.
- `common-control`: all 64 additional warm throughput observations, calibration,
  complete manifests, summary, and the execution adapter snapshot. The adapter
  records the original temporary paths; remap its setup constants when replaying
  it on another machine. It imports the unchanged conversion runner and driver.
  `verification-summary.json` records the 1,698 exact-byte/error comparison result
  and hashes of the complete verification receipts.
- `tests`: final debug/release and unchanged-baseline release logs using the same
  final test sources, with hashes and commands.

Build products, module caches, generated large inputs, and full encoded
verification outputs are not checked in. The fixture generator, source snapshots,
recorded commands and driver regenerate them. Snapshots are execution receipts;
use the current runner from its normal repository location for a fresh run.
