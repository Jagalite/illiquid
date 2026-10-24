# Compact PlexMatch episode storage

## Problem and change

`PlexMatchHints` keeps an index of explicit filename-to-episode mappings. The
baseline stores a complete `MediaMetadataHints` in every dictionary slot, but a
mapping only supplies an optional season, a required episode, and an optional
last episode. The title, year, episode title, catalog IDs, and source attribution
belong to the shared series metadata or remain absent in a raw mapping.

The candidate stores those three identity fields in a private `EpisodeMapping`.
`episodeHint` constructs the existing `MediaMetadataHints` return value on a hit.
The dictionary keys, parser limits, validation, duplicate replacement, lookup
signatures, metadata merge, and season fallback are unchanged.

This reduces the size of the dictionary's value storage. The baseline's absent
strings and empty arrays do **not** imply a separate heap allocation for every
field. Savings depend on dictionary capacity and allocator size classes, not
simply the number of mappings multiplied by a nominal struct-size difference.

`MediaSidecarReader` retains parsed `PlexMatchHints` in its cache for one background
scan. Its existing limits are 128 KiB per sidecar, 16 MiB of file bytes per reader,
and 50,000 cache entries. This change reduces memory held during that lifetime;
it does not change the cache policy or extend any object's lifetime.

## Qualification

The baseline parser comes from `4abf4b44f13386ccd04f1ce4ad0e756255ca4d14`.
The runner compiles actual production sources, with `PlexMatchHints.swift` as the
only differing production file. It snapshots the current four support files,
tests, and measurement driver identically for both variants, and records the
historical support hashes too. This keeps later support changes from invalidating
the comparison solely because they differ from an old commit. Source and binary
hashes accompany the raw observations.

Both representations run the same parser and real-filesystem sidecar regressions
in debug and release. The additional regressions compare complete raw and merged
metadata, preserve the distinction between an omitted season and season zero,
check replacement of an earlier season/range, and verify that mutating returned
hints cannot alter the stored index or its copies.

Native measurement and complete-output parity results will be recorded here
after the first successful qualification run. This initial branch does not claim
a measured improvement.

## Reproduction

On macOS with the repository's Swift toolchain:

```sh
python3 Benchmarks/PlexMatchEpisodeStorage/runner.py \
  --pairs 6 --target-ms 100 --output /tmp/plexmatch-episode-storage
```

The output directory must be new or empty. `--prepare-only` stages fixtures,
source packages, and provenance without compiling. It can run on another host
to inspect the experiment inputs; native memory qualification requires macOS.

Follow `AGENTS.md`: submit builds through Kyoto when its shared queue is available.
The dedicated GitHub Actions workflow runs in isolated ephemeral macOS packages
and explains the queue's absence before direct compilation. It retains evidence
both as an artifact and as a checksummed compressed bundle in the job log.

## Interpretation

The memory metric is allocator-reported in-use storage released when the measured
owner is dropped, after parse temporaries have drained. It is not process RSS,
reserved virtual memory, or a measurement of the entire player. The parser's
source-byte limits remain in effect in every fixture.

The workload includes a metadata-only control, small episode lists, a dense file
near the 128 KiB limit, and multiple files retained by a real sidecar reader.
Dense fixtures establish scaling under valid input limits; they do not establish
how often a typical library contains that many explicit mappings. Timing and
allocation results are reported separately, including slower timing samples.
