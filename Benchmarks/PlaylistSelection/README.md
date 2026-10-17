# Playlist selection identity lookup

This harness measures the production
`PlaylistMutation.indexPreservingCurrentIdentity` helper. The helper preserves
the current resource after playlist edits, sorting, and shuffle changes in the
main-actor playback coordinator. The candidate computes the current URL's
canonical key once per search, after finding the first eligible local item.

The comparison baseline is `main` at
`68274d1b09dcc866296321a5a8858efc297c4f19`. The four frozen source files retain
their original paths, Git blob IDs, and SHA-256 hashes in `baseline/manifest.json`.
Every run validates that manifest and snapshots the current candidate files.
`NormalizedFileURL` and its authority, Unicode, and filesystem policies are
unchanged by this optimization.

## Reproduce

Use Swift 6.1 or newer with bundled Swift Testing, and Python 3.10 or newer.
The application targets macOS 26; this isolated Foundation component also runs
on Linux. No external packages or native playback dependencies are resolved.

```sh
# Both variants, debug/release tests, full parity receipts and eight timing pairs.
python3 Benchmarks/PlaylistSelection/run.py --output /tmp/playlist-selection

# Both variants' debug/release tests only.
python3 Benchmarks/PlaylistSelection/run.py \
  --output /tmp/playlist-selection-tests --tests-only

# Small harness smoke run; do not publish its timings as a performance result.
python3 Benchmarks/PlaylistSelection/run.py \
  --output /tmp/playlist-selection-smoke --samples 2 --sizes 1 100
```

The output directory must not already exist. `--swift` and `--swiftc` accept
toolchain executables; use the same toolchain for both. Toolchains unpacked in
custom Linux locations may need their normal library search paths. Compiler
module caches are kept inside the output directory without replacing `HOME`.

The macOS workflow `playlist-selection-performance.yml` runs the same command
and uploads `playlist-selection-evidence`. These are component results; full
application behavior and physical-device playback are separate qualification.

## What is measured

| Workload | Selected resource and input |
| --- | --- |
| `head` | First local item; unchanged two-key control |
| `middle` | Middle local item |
| `tail` | Last local item |
| `missing` | Absent local resource, with a valid fallback |
| `tail-unicode` | Last local item in a playlist with accented, CJK, and emoji names |
| `missing-unicode` | Absent ASCII current URL searched among Unicode-named items |
| `invalid-current` | Remote file authority searched among local items; fallback required |
| `nil-current` | No current URL; use the fallback directly |
| `all-invalid-items` | Valid local current URL with only HTTPS items; no current key is needed |
| `empty` | Empty playlist, valid local current URL, no fallback |

The default sizes are 1, 100, 1,000, and 10,000 items, plus the empty control.
Each of the 37 workload/size combinations receives eight fresh-process pairs,
alternating baseline/candidate and candidate/baseline. Both members of a pair
use identical iteration counts. The predeclared budget is approximately 10,000
visited items per measurement; `head`, `nil-current`, and `empty` use 10,000
calls. Exact counts are retained in the run manifest and every observation.

The short-circuiting candidate for `invalid-current` can run only one call at
10,000 items under that budget. Its tiny timer interval is particularly noisy;
do not use it for a precise speedup claim. Cheap controls should likewise be
interpreted with their absolute times and ranges.

Production source is compiled into a separate optimized `IlliquidCore` shared
library with whole-module optimization. An independently compiled driver calls
the public helper without cross-module optimization or an inlinable copy of
its implementation. Every returned index contributes to a checked checksum.
Inputs, item normalization, expected results, and three warmup calls are outside
the timer. The timed loop includes the helper call and checksum accumulation.
Builds, tests, and measurements run sequentially.

For an all-local search visiting `s` items, the old helper evaluates `2s` keys;
the candidate evaluates `s + 1`. First-item matches still evaluate two keys.
Empty lists, nil current URLs, and lists containing only unsupported items
retain their inexpensive paths. The cache lasts for one invocation and retains
at most one additional key; it does not introduce an index or persistent cache.

## Correctness and evidence

The isolated packages run the existing playlist mutation, folder playlist, and
order restoration suites together with `PlaylistSelectionIdentityTests` in
debug and release against both source versions. The new tests state expected
indexes for duplicate identities, reordering, aliases, decoded noncanonical
items, unsupported authorities, and fallback boundaries. Both versions are
expected to pass because only the cost changes.

Before timing, the driver checks a deterministic corpus against the original
predicate and emits every result (7,296 selections in the Linux publication
cohort). Inputs include decoded URLs, Unicode and dot aliases,
local and remote authorities, duplicate items, reordered arrays, seeded mixed
arrays, absent queries, and valid/invalid fallbacks. Full baseline and candidate
receipts must match byte-for-byte; comparing only a digest is insufficient.
Each timing pair must also match iteration counts, operation counts, and result
checksums.

The runner retains source/test snapshots, toolchain and binary hashes, exact
commands and compressed stdout/stderr, parity receipts, raw timing observations,
medians, ranges, and paired ratios. It verifies these files after writing them.
`completed.json` appears only after all required checks succeed. Generated test
packages and build products are reproducible and need not be committed.

See [the research report](../../Documentation/PLAYLIST_SELECTION_PERFORMANCE.md)
for the publication cohort and its qualification limits. The checked-in evidence
combines individual compressed command outputs into `command-receipts.jsonl.gz`;
each record includes its original path and exact decompressed text. The retained
`commands.jsonl` hashes can be used to verify every reconstructed receipt.
