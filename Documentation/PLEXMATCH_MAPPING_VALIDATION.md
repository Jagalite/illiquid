# PlexMatch episode mapping validation

Research date: 2026-10-17. Baseline: `8c3cc3d4008d5d1b8d436bcf2d51d891382b6548`.

## Scope

This is an independent audit of explicit `.plexmatch` episode directives in
`Sources/IlliquidCore/MediaLibrary/PlexMatchHints.swift`. It does not change the
filename/date recognizer, catalog-ID merging, playback, or other agents' fixes.
The patch is independent of PR #11 and the Unicode date-filename PRs.

## Contract and root cause

[Plex's primary documentation](https://support.plex.tv/articles/plexmatch/)
describes explicit `ep`/`episode` hints, special/season numbering, episode ranges,
filename precedence, and series-versus-descendant mapping scope. This audit
preserves Illiquid's supported subset; pattern directives remain unsupported.

The old regular expression used ICU `\d` for four numeric captures. It matched
non-ASCII decimal digits that Swift `Int` could not convert. The parser treated
conversion failure as if an optional field were absent, then returned an episode
hint even if its required episode number was missing. The caller accepted that
hint and could replace a previously valid mapping for the same path.

This is not the separate filename date-indexing crash. The observed failures are
silent metadata corruption:

- A malformed explicit season such as `S０２E03` is replaced by a default or
  inherited season, while episode 3 still overrides the filename.
- `SP０１` can move a recognized ordinary episode into season zero while borrowing
  its episode number from the filename.
- `S02E03-E０５` is shortened to a single episode; an invalid explicit end season
  can disappear and evade the cross-season rejection.
- A later malformed directive can erase an earlier valid directive for the same
  filename, including its episode range.

A source-traced downstream consequence is also covered by macOS reader tests:
when a file contains only a malformed episode directive, accepting it as a real
`.plexmatch` file can establish a series boundary and suppress a valid deeper
relative-path mapping. An invalid-only file must instead parse as `nil`.

## Fix

Constrain all four numeric captures to `[0-9]`, matching the ASCII numeric
contract already used by the other metadata hints. Require successful conversion
of the mandatory first episode before constructing a hint. Keep existing bounds,
zero values, default seasons, special handling, same-season range checks, and
last-valid-directive precedence unchanged.

This rejects a malformed directive as a whole. It does not strip characters,
normalize Unicode digits, restrict Unicode titles/paths, or silently reinterpret
a partially valid directive. Future Unicode-number support should convert and
validate every supplied field atomically rather than weakening the grammar alone.

## Executed validation

The local environment is Linux x86-64 with Swift 6.2.1. Direct Git cloning was
unavailable, so the three Foundation-only files were obtained through the GitHub
connector and their Git blob hashes were verified before compiling:

| Source | Baseline Git blob |
| --- | --- |
| `MediaNameRecognition.swift` | `965c7b4e86fc1c2c99f05c6708545af4ca0d4d3d` |
| `MediaMetadataHints.swift` | `448fbb19456445a110985f57b31d1f27d9c28dc6` |
| `PlexMatchHints.swift` | `70b85d037e0d2bc355f0f02ee2e198f1f8196ede` |

No production source substitutions or stubs are used by the focused test runner.
The temporary package uses the toolchain's bundled Swift Testing rather than
resolving the application's pinned dependency graph.

- Negative control: the new 11-test suite against the unchanged baseline compiled
  and failed with **148 assertion issues**. This is an observed test failure, not
  merely a speculative code review finding.
- Candidate: the same **11 tests passed in debug and release**. The suite has 108
  parameterized cases plus six ordinary invocations, including a loop over 64
  single-digit mutations across eight digit sets. These are case/iteration
  counts, not additional independently named tests.
- Coverage includes all four captures, mixed ASCII/non-ASCII fields,
  supplementary-plane digits, filename evidence, duplicate directives, valid
  syntax, numeric bounds, Unicode titles/paths, inherited defaults, descendant
  restrictions, and existing input-size limits.
- A separate deterministic differential probe generated **2,064 ASCII receipts**
  for each of baseline-debug, baseline-release, candidate-debug, and
  candidate-release. All four outputs were byte-identical; their SHA-256 is
  `61d0bc68cfe55b8bf4dc27e29008d8938d0ed8df9822d7863470b3299e52d94f`.
  The probe and receipts accompany the research bundle; this is behavior parity,
  not a throughput, memory, or energy benchmark.
- `bash -n Scripts/test-plexmatch-regressions.sh` and `git diff --check` passed.

## Reproduction and remaining qualification

```sh
bash Scripts/test-plexmatch-regressions.sh
bash Scripts/test-plexmatch-regressions.sh --configuration release
```

On Linux this compiles the three real Foundation-only sources and runs the new
parser/application tests. On macOS it additionally compiles the actual NFO and
filesystem readers and runs the existing `MediaSidecarTests` plus three new reader
test functions (two parameterized over 26 malformed directives each).

The dedicated `PlexMatch mapping regressions` workflow runs both configurations
on the project's macOS/Xcode configuration and retains source/version receipts
and logs. Native filesystem tests and the full application were **not run locally**;
check the exact PR commit's CI results before claiming macOS qualification. No
independent sub-agent execution or native playback/performance qualification is
claimed. The change is narrowly scoped to metadata correctness.
