# Normalized file identity

This study compares file-key generation and the playlist operations that use it
against main at `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`.

## Hypothesis

`NormalizedFileURL.persistenceKey(for:)` currently calls `normalize(url)?.path`.
After validation, lexical standardization and Unicode NFC conversion, that
constructs an intermediate file URL and reads its path back. The candidate
returns simple printable ASCII paths directly while retaining the existing
local-authority validation. Unicode, control bytes, repeated slashes, dot-prefixed
components and non-root trailing slashes retain the original URL reconstruction.
This preserves Foundation's filesystem-representation behavior in those cases. URL-valued normalization and explicit filesystem resolution are
unchanged.

This is an experiment until the native compatibility and measurement gates
complete. No whole-player CPU, playback, frame-rate, energy or UI-latency claim
follows from these component measurements.

## Reproduce

Use Swift 6.1 or newer and Python 3.10 or newer. On macOS, select the repository's
Xcode configuration. The pinned baseline must exist in the checkout's Git history.

```sh
export DEVELOPER_DIR=/Applications/Xcode_26.6.app/Contents/Developer
python3 Benchmarks/NormalizedFileIdentity/run.py \
  --output /tmp/illiquid-file-identity --pairs 10 --target-ms 150
```

The output directory must be new or empty. Build commands run serially.
If the shared Kyoto queue is available, coordinate builds through it as required
by `AGENTS.md`. The isolated CI host has no Kyoto installation.

## Method

The runner builds the exact baseline and candidate production sources in
separate optimized Swift modules, then links the same driver to each without
cross-module optimization. It runs the new file-identity tests and the existing
local-source, utility and playlist regression suites against both variants in
debug and release configurations. Complete fixture/output comparisons precede
timing; key strings are compared as UTF-8 bytes.

Nine synthetic workloads cover ordinary paths, decomposed-Unicode fallback controls, escaped
localhost URLs, rejected-source controls, tail and missing playlist lookups, and
unique/repeated playlist deduplication. Key workloads report time per key.
Lookup and deduplication workloads report time per complete operation at the
specified playlist size. Fixture creation and sorting happen before timing;
output consumption and bounded autorelease-pool cleanup are included.

Each fresh process warms the operation before measurement. Calibration gives
both variants the same iteration count, targeting at least 150 ms for the
faster variant. Ten adjacent pairs alternate AB/BA, and case traversal reverses
each round. Wall time, process CPU time, exact iteration counts and checksums are
retained for every sample. There is no noisy timing threshold in CI.

The output includes source/binary hashes, environment and command receipts,
test logs, full verification logs, calibration, all observations and summaries.
The macOS workflow uploads full artifacts and emits compact receipts in its log
so the final research record can be retained with the change.
