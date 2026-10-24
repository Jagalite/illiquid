# Compact PlexMatch episode storage

The compact representation reduced allocator-reported storage released at teardown
by **42–46% in the four larger Linux fixtures, starting at 24 mappings**. All six pairs produced identical
memory results. The dense 32-sidecar stress case saved approximately **20 MiB**.

**Native macOS qualification is still queued.** These are adapted Linux component
results; the proposed change remains a draft until the
[native run](https://github.com/Jagalite/illiquid/actions/runs/40103110705) qualifies
the target platform. The study establishes no RSS, whole-player memory, playback
speed, or CPU non-regression result.

## Problem and change

`PlexMatchHints` keeps an index of explicit filename-to-episode mappings. The
baseline stores a complete `MediaMetadataHints` value in every dictionary slot,
but a raw mapping only supplies an optional season, a required episode, and an
optional last episode. Title, year, episode title, catalog IDs, and source
attribution belong to the shared series metadata or remain absent in a raw mapping.

The candidate stores the three identity fields in a private `EpisodeMapping`.
`episodeHint` constructs the existing `MediaMetadataHints` return value on a hit.
The dictionary keys, parser limits, validation, duplicate replacement, lookup
signatures, metadata merge, and season fallback are unchanged. An omitted season
remains distinct from explicit season zero, and a later single-episode mapping
still clears an earlier explicit season or range.

This reduces the dictionary's value storage. The baseline's absent strings and
empty arrays do **not** imply a separate heap allocation for every field. Actual
savings depend on dictionary capacity and allocator size classes, rather than
simply mapping count multiplied by a nominal struct-size difference.

`MediaSidecarReader` retains parsed mappings in its cache for one background scan.
Its existing limits are 128 KiB per sidecar, 16 MiB of input bytes per reader, and
50,000 cache entries. This change reduces storage during that lifetime without
changing cache policy or extending any object's lifetime.

The production change is confined to `PlexMatchHints.swift`: 23 added lines and
13 removed lines. The remaining files provide regressions, the measurement
protocol, CI, and evidence.

## Repeated Linux allocation results

Swift 6.3.2, x86-64 Linux, optimized Swift 6 language mode. Six balanced AB/BA
pairs per scenario, with a fresh process for every variant and scenario:
**72 successful processes** in total. The probe reads
`mallinfo2().uordblks + hblkhd` while the actual parsed owner is retained and again
after explicit teardown. Values below are the difference between those samples.

| Workload | Input bytes | Baseline bytes released | Candidate bytes released | Saved storage | Reduction |
|---|---:|---:|---:|---:|---:|
| Metadata only, 0 mappings | 78 | 0 | 0 | 0 | — |
| 1 mapping | 107 | 0 | 0 | 0 | — |
| 24 mappings | 888 | 6,128 | 3,552 | 2,576 bytes | 42.04% |
| 1,024 mappings | 34,938 | 360,560 | 196,704 | 163,856 bytes | 45.44% |
| 3,847 mappings, near the file limit | 131,059 | 1,422,816 | 767,456 | 655,360 bytes | 46.06% |
| Reader caching 32 dense sidecars | 4,193,792 | 45,592,624 | 24,621,472 | 20,971,152 bytes | 46.00% |

Every displayed memory value and paired reduction was identical in all six
pairs; the observed minimum and maximum therefore equal the displayed values.
Allocator caching can leave freed small blocks counted by `mallinfo2`, so the
zero- and one-mapping controls do **not** establish zero actual allocation. No
memory reduction is claimed for those two controls under this metric.

The near-limit file is 13 bytes below the parser's 128 KiB bound. The 32-file
fixture contains **123,104 explicit mappings**, uses less than the reader's
16 MiB input budget, and deliberately exercises dense valid inputs. Smaller
lists produce smaller absolute savings. All 12 cache processes read exactly
32 sidecars, then performed zero additional reads on the repeated pass.

### Timing observations

The protocol also records parse-plus-one-lookup-and-release, successful raw
lookups, missing raw lookups, and successful merged lookups. Each process
calibrates its own iteration count, targets 100 ms, and includes an identical
scalar consumer and per-iteration autorelease-pool wrapper. Deterministic Swift
hashing is enabled for both variants.

Shared-host wall-clock timings were highly variable. Individual paired
candidate/baseline ratios ranged from approximately **0.00284 to 20.49** across
metrics and workloads. These observations cannot support a speed improvement or
a CPU non-regression claim. Every observation and paired ratio is retained in
the evidence; native timing qualification remains outstanding.

## Functional and evidence qualification

The same current pure-parser regression suite passed against both representations
in debug and release: **14 reported tests per run, four successful runs**. These
tests compile the exact three production source files without substitutions.
The additions compare complete raw and merged metadata, nil versus zero seasons,
replacement that clears an earlier season/range, and mutation independence of
returned hints and copied indexes.

A separate optimized benchmark process compared complete semantic outputs before
the repeated cohort. It covered 4,920 queries across six fixtures, with raw,
merged, default-season, and descendant-restricted results, plus real reader
recognition and the 32-sidecar cache exercise. All `MediaMetadataHints` and
`RecognizedMediaName` stored fields are recorded, including explicit nulls.
Baseline and candidate output matched byte-for-byte and as parsed JSON:

```text
4c5148fea2cf7b086ca51c85f0d86c70a135bf406e4ca6e9a8be32d013681ab9
```

The repeated cohort used those same binaries and fixtures. All 126 recorded input
hashes remained unchanged before and after it. Independent review recomputed
all 72 measurements, paired reductions, timing ratios, command exit codes, log
hashes, and the test/source correspondence.

The Linux benchmark preserves the native harness bytes. Its explicitly archived
platform adaptations are the POSIX/XML imports in two support files, a separate
no-op autorelease-pool shim, and the glibc heap probe. No parser, metadata model,
dictionary, or reader implementation body is replaced. The real reader exercise
is part of benchmark parity and sampling; the Linux unit-test count is for the
pure-parser suite. Native reader and sidecar unit suites remain pending.

An initial managed-sandbox Swift compilation failed before tests. The isolated
approved retry passed all four configurations without source changes. Kyoto was
unavailable, so local builds ran serially in separate temporary packages.

## Native protocol and reproduction

The baseline parser comes from `4abf4b44f13386ccd04f1ce4ad0e756255ca4d14`.
The runner compiles actual production sources, with `PlexMatchHints.swift` as the
only differing production file. It snapshots the current four support files,
tests, and driver identically for both variants, retaining historical support
hashes and snapshots too. In this cohort, all support bytes equal the historical
baseline. This allows future shared-support changes without silently mixing two
different dependency sets.

The native probe uses `malloc_zone_statistics(NULL).size_in_use`. It measures
allocator-reported component storage released by teardown, with the owner and
input buffers kept alive across the held sample and parse temporaries drained.
The payload is consumed before and after the held probe; only scalar checksums
escape validation. The owner itself exists before installation and after release,
so its fixed allocation is excluded.

On macOS with the repository's Swift toolchain:

```sh
python3 Benchmarks/PlexMatchEpisodeStorage/runner.py \
  --pairs 6 --target-ms 100 --output /tmp/plexmatch-episode-storage
```

The output directory must be new or empty. `--prepare-only` stages fixtures,
source packages, and provenance without compiling. Native execution additionally
runs the real filesystem reader and sidecar regression suites against both source
variants in debug and release before semantic parity and measurement.

Follow `AGENTS.md`: submit builds through Kyoto when its shared queue is available.
The dedicated workflow uses isolated ephemeral macOS packages and explains the
queue's absence before direct compilation. It preserves evidence as an artifact
and as a checksummed compressed bundle in the job log.

## Permanent evidence

- [Readable repeated-study summary](evidence/linux-repeated-summary.json): every
  memory range, paired reduction, timing median, and individual paired ratio.
- [Repeated-study archive](evidence/linux-repeated.tar.gz) and
  [SHA-256 receipt](evidence/linux-repeated.json): all 72 stdout/stderr pairs, raw
  samples, commands, pre/post input hashes, platform diff, test receipts, summary
  helper, and the exact cohort script.
- [Pure-test and initial smoke archive](evidence/linux-validation.tar.gz) and
  [SHA-256 receipt](evidence/linux-validation.json): complete unique semantic
  output, exact source snapshots, compiler and binary hashes, platform adapters,
  four successful test logs, and the deterministic fixture recipe.

The archives are complementary: the repeated study records the unchanged prior
semantic archive and its hash, avoiding duplicate multi-megabyte outputs. Neither
archive includes build caches or compiler executables. The Linux cohort script
and adapter sources are preserved as experiment receipts; the checked-in runner
above remains the native reproduction entry point.
