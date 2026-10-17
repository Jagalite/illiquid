# Folder-discovery selective I/O research

Date: October 17, 2026. Base: `8c3cc3d4008d5d1b8d436bcf2d51d891382b6548`.

## Scope and decision

Retain a small optimization in `FolderPlaylistDiscovery.discover`. This is an
independent folder-scanning investigation, not a continuation of the playback
pipeline work. Subtitle matching rules, NFO parsing, playlist mutation, stored
identities and playback behavior are unchanged. No user files are modified.

Previously, discovery requested file type and three date properties for every
visible child, resolved every path, then read regular-file/date metadata before
filtering supported extensions. Dates for subtitles and unsupported files never
contribute to the resulting playlist.

The retained change prefetches symbolic-link status instead. It skips unsupported
names only when the entry is known not to be a symbolic link. Unknown or failed
link-status reads retain the resolution path. Resolved targets are classified
again before regular-file metadata; dates are read only for accepted media.
The existing date-precedence helper is unchanged. Production diff: 14 added and
7 removed lines in one file; the rest is tests, a runner and evidence.

Apple documents that `includingPropertiesForKeys` fetches/caches the requested
properties for each returned URL, and that this directory API itself does not
traverse symbolic links. Therefore a filename-only prefilter is not equivalent
to the existing discovery behavior: this app explicitly resolves the links after
listing them. [Apple Foundation documentation][1]

## Rejected approach

An experimental filter using only the visible filename dropped valid
extensionless/misnamed media and subtitle links. It was rejected, not published
as production code. The initial 17-test suite produced 10 failed expectations
against that negative control, while baseline and the symlink-aware candidate
passed. The final suite additionally checks relative/chained symlinks.

No caching of filesystem identities or arbitrary scan limits were introduced.

## Measured results

Linux x86_64, Swift 6.2.1, `swiftc -swift-version 6 -O`. These are warm local
filesystem scans of generated empty files, not macOS app-open latency, media
parsing, remote-volume performance or energy measurements.

| Fixture | Baseline median (ms) | Candidate median (ms) | Change |
| --- | ---: | ---: | ---: |
| empty | 1.118 | 1.274 | +14.0% |
| small | 2.573 | 2.459 | -4.4% |
| media-only | 49.034 | 48.131 | -1.8% |
| mixed | 508.140 | 218.336 | -57.0% |
| unsupported-only | 497.840 | 199.877 | -59.9% |
| subtitle-heavy | 127.238 | 82.978 | -34.8% |
| symlink-rich | 42.351 | 43.017 | +1.6% |

Fixture composition:

- `empty`: no children. `small`: 3 videos and 3 subtitles.
- `media-only`: 250 videos. `mixed`: 25 videos, 25 subtitles, 5,000 text files.
- `unsupported-only`: 5,000 text files. `subtitle-heavy`: 25 videos, 1,000 subtitles.
- `symlink-rich`: 100 media, 100 subtitle and 100 text targets accessed through
  extensionless aliases, plus broken, directory and hidden link controls.

The supported-media-only and symlink-rich controls do not establish a meaningful
speedup. The empty case is 0.156 ms slower at the medians; its ranges overlap.
Do not extrapolate percentage changes in that tiny control to application
latency. The retained optimization targets mixed/unsupported-heavy directories.
No syscall counts, memory improvements or macOS speedups are claimed.

### Method and receipts

The benchmark compiles the seven real production sources independently for each
variant, without stubs or a rewritten scanner. Git blob hashes are recorded in
`Benchmarks/FolderDiscovery/RESULTS.json`. All source inputs except
`FolderPlaylistDiscovery.swift` are identical. Directory creation, process
startup and JSON encoding are outside the Swift discovery timer (first-use
Foundation work within `discover` remains included).

Seven fixtures, nine measured pairs per fixture, and one excluded warm-up pair
per fixture produce **140 fresh processes: 126 timed observations and 14 warm-ups**.
Pair order alternates between baseline-first and candidate-first. Every process
must produce the expected item count and exactly the same full receipt for its
fixture: ordered URLs, external subtitle URLs, metadata dates and folder URL.
All 140 receipts matched. Each duration, pair order and verified receipt hash is
retained in the compact results file; min/max values are included alongside the
medians. The reproduction script also writes the full JSON receipts separately.

### Correctness tests

The standalone suite compiles actual Foundation-only production sources and the
three existing discovery tests plus 15 new test functions (several parameterized).
The final baseline and candidate debug runs, and the optimized candidate run,
each passed all **18 tests in two suites** on Linux. Coverage
includes mixed files, supported uppercase extensions, all five supported
subtitle extensions through symlinks, extensionless and misleading links,
relative/chained links, broken links, directory links, hidden entries, duplicate
media aliases, link retargeting between scans, folder aliases, named pipes,
missing folders, and cancellation before/during scanning. File contents are not
opened, so testing a named pipe does not block waiting for a producer.

The dedicated macOS CI workflow runs this focused suite in debug and release.
Its existence is not a claim of a passing run or a full native application test.

## Reproduction

```bash
bash Scripts/test-folder-discovery-regressions.sh -c debug
bash Scripts/test-folder-discovery-regressions.sh -c release

git worktree add /tmp/illiquid-folder-base 8c3cc3d4008d5d1b8d436bcf2d51d891382b6548
python3 Benchmarks/FolderDiscovery/run.py \
  --baseline-root /tmp/illiquid-folder-base \
  --candidate-root "$PWD" --output /tmp/folder-results.json
```

Swift 6.1+ and Python 3.10+ are required. The isolated test runner avoids resolving
the native SDK/dependency graph. Timing assertions are deliberately absent from
unit tests. Comparisons fail on mismatched receipts or unexpected item counts.

## Remaining qualification and limitations

Require the focused macOS CI checks before merging, and validate opening a mixed
folder and a folder with symlinks in the app. Repeat the benchmark on APFS and
representative removable/network volumes before making macOS performance claims.

This still uses a full shallow directory listing and existing model sorting;
it is not a streaming scan or a hard filesystem-I/O timeout. Cancellation is
cooperative and cannot interrupt a blocked Foundation call. Directory mutation
is not an atomic snapshot: an entry replaced after its prefetched classification
may require rediscovery. Retargeting between separate scans is covered. No new
guarantee is made about Finder aliases, permission changes during a scan, network
disconnections, or simultaneous in-place replacements.

[1]: https://developer.apple.com/documentation/foundation/filemanager/contentsofdirectory(at:includingpropertiesforkeys:options:)
