# PlexMatch episode parsing

This experiment compares a bounded ASCII episode-number scanner with the
complete production parser at main revision
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`.

The common spellings (for example, S02E03-E05) avoid ICU matching and capture
conversion. The original regex remains the fallback for noncontiguous UTF-8,
non-printable or non-ASCII input, and tokens longer than 19 bytes. The fast path
does not change directive/path validation, mapping storage, duplicate replacement,
metadata precedence, or parser limits.

## Reproduce

Run on macOS 26 with Xcode selected. Use the shared Kyoto queue when it is
available, as required by AGENTS.md:

```sh
python3 /Volumes/seed1/Projects/kyoto/kyoto.py submit -- \
  python3 Benchmarks/PlexMatchParsing/run.py --rounds 10 --target-ms 100 \
  --output /tmp/illiquid-plexmatch-parsing
```

Inspect the queued job's show/logs/wait results before reporting completion.
When Kyoto is unavailable, explain that limitation before running the same
Python command directly. The runner uses fresh output directories and serial,
isolated build paths. It does not fetch external package dependencies.

The default baseline is pinned to the main revision above. Pass
`--baseline-ref COMMIT` to make a new comparison; the runner resolves the
commit and records hashes of every actual input. It requires that only
PlexMatchHints.swift differ between the two sets of production sources.

## Method

Both variants compile the same five complete production media-library files,
changing only PlexMatchHints.swift. The same parser and filesystem-sidecar
regression suites run against both variants in debug and release.

A separately compiled optimized driver compares complete metadata receipts for
a deterministic valid/malformed token corpus, including standalone mappings,
metadata inheritance, duplicate replacement, default seasons, and descendant
restrictions. It also compares every indexed mapping in the timing fixtures.

Timing measures full public parse, one raw mapping lookup, an observable scalar
consumer, and teardown in an autorelease pool. Fixture generation, input decoding,
and warm-up are outside timing. Each fixture calibrates a shared iteration count
for both variants, then runs ten fresh-process pairs with balanced AB/BA order.
Deterministic Swift hashing is set equally for both. All raw samples, paired
ratios, compiler/source/binary hashes, and complete semantic receipts are retained.

Fixtures cover metadata only, 1/24/1,024 mappings, a file near the 128 KiB limit,
Unicode-prefix fallback, malformed ASCII mappings, and a long-invalid-token
control. The dense fixture is a boundary stress case; it does not represent the
typical sidecar. Timings establish component parsing cost, not total source-scan,
media-open, playback, or frame-rate improvements.

## Status

Native qualification is pending. Results will be recorded after the isolated
research workflow completes; no performance claim is made by this initial commit.
