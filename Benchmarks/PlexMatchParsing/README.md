# PlexMatch episode directive parsing

This experiment measures complete `.plexmatch` parsing against
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`, which already contains the compact
episode mapping representation. Only the episode-token parser differs between
the production variants. This is independent of the earlier episode-storage
memory optimization.

## Change and scope

Most explicit episode directives use a short ASCII grammar: `E12`, `SP12`,
`S02E12`, or ranges such as `S02E12-S02E14`. The baseline runs ICU matching,
converts captured ranges between UTF-16 and Swift strings, parses the captures,
and uppercases the token to recognize specials on every directive.

The candidate parses tokens of at most 19 printable ASCII bytes directly. It
preserves digit-width limits, leading zeros, omitted versus zero seasons,
same-season ranges, and complete input consumption. Non-ASCII, control-byte,
and longer inputs retain the original regex implementation. In particular,
ICU's acceptance of U+017F long s as a case-insensitive `S` remains supported.
There is no new cache, retained per-mapping field, or parser dependency.

`MediaSidecarReader` parses a sidecar on a cache miss and reuses the result
during a scan. This study measures that parsing component, including one lookup
and result destruction. It does not establish an equivalent change in library
scan latency, playback CPU, frame rate, memory use, or battery life.

## Qualification

Native qualification results will be recorded here after the branch workflow
completes. Local exploratory measurements showed substantial shared-host noise,
including changes in untouched control paths, and are not a performance claim.

## Reproduce

Follow the repository's `AGENTS.md`: use the shared Kyoto build queue when it is
available, and inspect the completed job before claiming validation. The
ephemeral macOS workflow explains its absence before direct isolated builds.

```sh
python3 Benchmarks/PlexMatchParsing/run.py \
  --pairs 12 --target-ms 150 --output /tmp/plexmatch-parsing
```

Use a fresh output directory. The runner never overwrites prior evidence.
`--swiftc` / `SWIFTC` and `--swift` / `SWIFT` select an installed matching
toolchain. On macOS the default resolves Xcode's compiler and SDK explicitly and
targets macOS 26. On Linux it compiles the same three parser/model source files
without platform substitutions. Linux cannot qualify native filesystem reader
behavior or macOS performance.

For a smoke check only:

```sh
python3 Benchmarks/PlexMatchParsing/run.py \
  --pairs 2 --target-ms 10 --output /tmp/plexmatch-parsing-smoke
```

`--skip-tests` is intended for exploration, and is recorded in the manifest.
Final qualification runs the same current regression tests against both
implementations in debug and release. On macOS these also include the real
`MediaSidecarReader` and filesystem sidecar suites. No external Swift packages
are required for these isolated tests.

## Workloads and timing boundary

The 18 timed fixtures cover:

| Group | Inputs |
| --- | --- |
| Ordinary season-qualified mappings | 1, 24, 256, and 2,000 paths |
| Mixed bare, episode, special, and range syntax | 24, 256, and 2,000 paths |
| Unicode controls | 256 Unicode-prefix tokens; 256 Unicode paths with ASCII tokens; 256 mixed ASCII/Unicode tokens |
| Malformed directives | 256 invalid tokens with metadata; the same directives without metadata |
| Replacement | 256 target paths with valid, replacement, and invalid-later directives |
| Maximum accepted size | Exactly 128 KiB with 4,297 valid mappings and comment padding |
| Other controls | Empty, metadata-only, a long invalid token, and an oversized document |

`mappingPaths` describes the fixture's target mapping paths, including rejected
attempts. `episodeDirectives` counts actual input directives; neither field is
an assertion that every directive was accepted. The replacement workload has
768 directives for 256 paths.

Fixture construction, warmup, JSON output, and full-output validation occur
outside timing. Each timed operation calls the actual `PlexMatchHints.parse`,
performs one merged lookup and scalar consumption, and releases the parsed
result. On macOS it also drains a per-operation autorelease pool. Thus the
reported nanoseconds are for parse-plus-lookup-and-destruction, not an isolated
regex or byte-parser helper. CPU uses `CLOCK_PROCESS_CPUTIME_ID`; wall time uses
`CLOCK_MONOTONIC`. Both are retained for every observation.

The runner builds the baseline and candidate as separately optimized shared
`IlliquidCore` libraries and links the same independently optimized harness to
each one. No cross-module optimization or inlinable parser body is enabled, so
the harness cannot hoist parsing out of its measured loop. Every operation
contributes to a retained checksum.

Pilot processes calibrate each fixture until the faster variant reaches the
requested CPU interval. Both variants then use the same fixed iteration count
for all final pairs. Final measurements run serially in fresh processes, with
six AB and six BA pairs per fixture by default and fixture order rotated between
pair orders. Deterministic Swift hashing is enabled equally for timing; normal
unit and differential tests retain their usual hashing behavior. Calibration
observations are separate from final measurements.

The summary reports both median paired ratios and ratios of separate medians,
all individual paired ratios, faster-pair counts, and observed ranges. Timing
percentages are evidence to review, not a flaky percentage-based CI gate.

## Correctness and provenance

Before timing, each executable emits the same complete semantic receipt for
76,709 generated tokens in three contexts: direct mapping, inherited metadata,
and replacement of a prior valid mapping. The corpus exhausts short strings
over a grammar alphabet and systematically covers digit widths, mixed case,
ranges, Unicode case folding and digits, insertions, controls, separators, and
oversized tokens. The runner compares the full receipt bytes, not only an
aggregate checksum.

It also compares all metadata fields and per-path lookups for the complete
documents, with descendant mappings enabled/disabled and default seasons absent,
zero, and nine. Independent regression tests check raw mapping identity and
specific expected semantics, including canonical-equivalent path replacement.
The original regex body remains intact as the uncommon-input fallback.

The pinned baseline records its Git commit, Git blob ID, and SHA-256. CI verifies
its bytes against the original repository blob. Each run snapshots the actual
production sources, baseline, harness, runner, and tests, and records the compiler
and frontend hashes, SDK, exact commands, binary hashes, logs, and raw
measurements. A final hash check rejects results if inputs changed during the
run. Generated packages and build products stay outside the evidence directory.

The branch workflow uploads full evidence, including both full differential
receipts, as `plexmatch-parsing-native`. Its compact log bundle retains source
snapshots, test logs, timing observations, and the complete-receipt hashes. The
normal PR workflow separately supplies the broader native release test suite.
