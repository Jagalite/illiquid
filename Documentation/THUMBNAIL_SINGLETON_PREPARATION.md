# Singleton thumbnail neighborhood preparation

## Scope

This is a focused follow-up to [PR #132](https://github.com/Jagalite/illiquid/pull/132)
at `8637a8d2c6a628699d5a552a55061b4e0bfc6f10`. That change removes the full-playlist
URL projection from optional background/library thumbnail scheduling, but its
research records extra overhead for a single-item playlist. A separate
concurrent study, [PR #135](https://github.com/Jagalite/illiquid/pull/135), reports
the same small-input tradeoff.

The benchmark compares #132's already-bounded helper with the singleton change,
isolating the remaining construction overhead. Automatic current-video-only
preparation uses a separate scheduler path.

## Change

After the existing nil-current check, a singleton is handled directly. A matching
stored URL produces one URL and its zero distance through collection literals.
A mismatch produces empty output. This avoids index-search, range, reservation,
and append-loop setup for a result whose complete shape is already known.

The returned URL and dictionary key come from the playlist item, preserving its
representation even if the query compares equal. The general path continues to
use the first matching URL, ordered bounded window, and last-write distance
semantics for duplicates.

Both baseline and candidate already retain at most nine URLs and nine distances.
This experiment measures construction overhead. It does not establish an
additional asymptotic memory improvement, allocator delta, process RSS reduction,
or playback-frame benefit.

## Regression coverage

The isolated test slice compiles unmodified production support sources and runs
both the pinned bounded helper and the candidate in debug and release. The
existing six test functions include 5,465 generated small-playlist cases per
configuration, clipped boundaries, duplicate distances, raw URL equality, and a
10,000-item playlist.

The added regression checks decoded single-item file, remote, relative,
percent-escaped, and Unicode URL representations. It compares the returned
`absoluteString`, `relativeString`, and `baseURL`, including the dictionary key,
and covers matching, absent, standardized, absolute, and nil queries.

## Benchmark method

Both complete helper sources are compiled as a separate optimized `IlliquidApp`
module with identical `IlliquidCore` support and an identical driver. There are
no baseline source rewrites. The driver consumes result counts inside each timed
loop; exact URLs and distances are checked before and after timing and across
variants. Input construction and URL normalization remain outside timing.

The workload includes matching, missing, and nil singletons plus 2-, 8-, 32-,
and 10,000-item controls. Repeated positions that are identical for singletons
are omitted. Eight balanced AB/BA pairs run in fresh processes for each workload.
Calibration uses up to four retained trials per variant to reach at least 80%
of a 50 ms target, with a five-million-call cap. All calibration records and
all accepted timing samples are retained; there is no timing pass/fail threshold.

The measurements describe repeated synchronous preparation throughput on the
reported host, including result count consumption and destruction. They do not
include actor scheduling, candidate ranking, native decoding, or presentation.
Cross-platform results are reported separately.

## Reproduce

Follow `AGENTS.md` and submit compilation through Kyoto when it is available.
Hosted workflows verify its absence before building serially in isolated
checkouts.

```sh
git fetch --no-tags origin 8637a8d2c6a628699d5a552a55061b4e0bfc6f10
ILLIQUID_SINGLETON_HELPER_REF=8637a8d2c6a628699d5a552a55061b4e0bfc6f10 \
  bash Scripts/test-thumbnail-singleton.sh --jobs 2 --no-parallel
bash Scripts/test-thumbnail-singleton.sh --jobs 2 --no-parallel
python3 Benchmarks/ThumbnailSingleton/run.py \
  --rounds 8 --target-ms 50 --counts 1,2,8,32,10000 \
  --output /tmp/thumbnail-singleton-results.json
```

The portable workflow pins the official Swift 6.3.3 Noble image by its observed
digest. The inherited native workflow also measures this comparison and includes
the new regression when compiling/testing the full app graph.

## Results

Results and permanent raw evidence will be recorded after CI qualification.
Live player interaction and native performance remain unqualified until their
corresponding checks execute.
