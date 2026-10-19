# Natural filename ordering

Folder discovery sorts media URLs, and `FolderPlaylist` sorts complete items
when it is constructed. External subtitle association and item construction
also sort subtitle URLs. The previous comparator extracted both filenames on
every comparison, including when an item had already participated in many
comparisons.

The candidate extracts each filename once into a temporary array, sorts those
records, and returns the original values. `FolderPlaylist` uses the same internal
helper, preserving dates, subtitles, duplicates, and URL representations. The
existing `localizedStandardCompare` and literal original-path tie-break remain
the ordering rules. Paths are still extracted only for filename ties. Empty and
singleton arrays return immediately; pairs use the original comparator without
allocating cached records.

The retained baseline is the integrated main revision
`68274d1b09dcc866296321a5a8858efc297c4f19`. Its three source files are retained
unchanged under `baseline/`, with SHA-256 and Git blob identities checked before
each run.

## Native macOS results

[Qualification run 39067064223](https://github.com/Jagalite/illiquid/actions/runs/39067064223)
completed on 2026-10-17 using macOS 26.6.2, an arm64 runner with three logical
CPUs, Apple Swift 6.3.3, and the `en_US` Foundation locale. The measured candidate
is commit `65aeb04b0399741cf974ccab4f740ad0cb428c71`; its production sources and
Swift benchmark driver are unchanged in this PR.

The table gives per-variant median elapsed time per operation. The last column
is the median of the six paired percentage reductions, so it is not necessarily
the percentage computed from the two independent medians.

| Operation and input | Baseline median | Candidate median | Paired median reduction |
| --- | ---: | ---: | ---: |
| Sort 100 shuffled natural names | 1.498 ms | 0.583 ms | 60.2% |
| Sort 1,000 shuffled natural names | 19.856 ms | 7.324 ms | 62.3% |
| Sort 10,000 shuffled natural names | 200.906 ms | 63.076 ms | 68.8% |
| Construct playlist, 1,000 shuffled natural names | 26.490 ms | 11.512 ms | 55.7% |
| Construct playlist, 10,000 shuffled natural names | 253.956 ms | 84.339 ms | 60.9% |
| Construct playlist, 10,000 already sorted natural names | 11.636 ms | 9.470 ms | 12.8% |
| Construct playlist, 10,000 reversed natural names | 12.868 ms | 10.541 ms | 14.8% |
| Sort 10,000 long Unicode names | 1,355.411 ms | 152.439 ms | 88.4% |
| Sort 10,000 identical names in different directories | 447.661 ms | 319.884 ms | 29.6% |
| Construct item with two subtitle URLs | 5.214 µs | 5.347 µs | **−3.8%** |

All six pairs improved for shuffled natural-name sorting at each of the three
sizes. For 10,000 names, individual paired reductions ranged from 59.8% to
79.4%; playlist construction ranged from 56.9% to 70.1%. These gains are large
enough to support caching the repeatedly extracted filenames.

All 30 cases with at least 100 entries improved at the paired median, but some
individual observations were slower. Already ordered work is shorter and noisier:
for example, 10,000 reversed-name sorting ranged from an 18.4% slowdown to a
30.2% improvement. This is one hosted-runner experiment, not a confidence bound
or a guarantee for every machine and locale.

The two-subtitle control is a small cost that remains visible: direct sorting
went from 1.305 to 1.426 µs (12.7% paired median slowdown, slower in five of six
pairs), and actual item construction went from 5.214 to 5.347 µs (3.8% paired
median slowdown, slower in four of six pairs). The roughly 0.13 µs additional
item-construction cost is accepted alongside the larger-list savings. Empty-item
construction was approximately flat. No claim depends on the nanosecond-scale
empty/singleton sorting results.

Debug and release qualification each passed **22 tests in four suites**, including
nine new ordering tests. Both benchmark binaries passed 14 additional verification
checks with the same receipt, and all 456 timed observations passed complete
output verification.

The permanent [macOS evidence](evidence/macos/) includes the
[full summary with ranges](evidence/macos/summary.json),
[all raw observations](evidence/macos/observations.jsonl), exact staged sources,
every command and its output, environment/compiler information, and
[run provenance](evidence/macos/provenance.json). The downloaded artifact matched
GitHub's SHA-256. A separate audit reproduced all 38 summaries from the 456 raw
rows, matched each row to its command receipt, and checked source fingerprints.
Individual per-command files duplicate `commands.jsonl` and are omitted from
the checked-in copy, as are executables and module caches.

## Reproduce

Use the project's macOS/Xcode toolchain for the shipping-platform result. The
benchmark itself compiles only Foundation sources and also runs with a Linux
Swift toolchain; it needs no native playback SDK or generated media fixtures.

```sh
# Production playlist behavior, including the independent ordering oracle:
bash Scripts/test-playlist-restoration.sh
bash Scripts/test-playlist-restoration.sh -c release

# Full paired baseline/candidate matrix; output must be a new directory:
python3 Benchmarks/NaturalFilenameOrdering/run.py \
  --samples 6 --output /tmp/illiquid-natural-ordering

# A short parity/build smoke run, without the full measurement matrix:
python3 Benchmarks/NaturalFilenameOrdering/run.py \
  --quick --samples 2 --output /tmp/illiquid-natural-ordering-smoke
```

`--swiftc /absolute/path/to/swiftc` selects another compiler. The output records
its resolved path, version, command arguments, and host/locale information.
The normal playlist workflow runs the short parity smoke; the full six-pair
research matrix is available through the command above. Neither has a timing
acceptance threshold.

## Measurement and correctness

The full matrix contains 38 cases and six paired samples by default: 456 timed
observations in fresh processes. Baseline-first and candidate-first order
alternate between samples. Both binaries compile exact staged source files and
the same driver using `-O -whole-module-optimization -swift-version 6`.

The matrix covers URL sorting and full playlist construction at 100, 1,000, and
10,000 entries. Natural names are shuffled, sorted, or reversed. Additional
cases use long Unicode names and identical filenames in different directories.
The already sorted construction cases represent the second sort during folder
discovery. Zero-, one-, two-, and eight-subtitle controls exercise direct sorting
and actual `FolderPlaylistItem` construction.

Fixture creation, reference sorting, warmup, full equality checks, and hashing
are outside the timer. Each measured iteration includes an identical constant
cost observer that reads a varying result position. This keeps results observable
and means the tiny controls include overhead beyond the sort itself.

The driver checks results against an independent copy of the old comparator,
including complete item metadata and exact UTF-8 URL representations. Baseline
and candidate output receipts must match within each pair and across repetitions
of each case. The production tests additionally cover canonical Unicode spellings,
case and numeric variants, escaped/relative/base URLs, comparator-equal remote
URLs, duplicate stability, held input arrays, and decoded items whose original
subtitle order must survive playlist sorting.

Each run retains `observations.jsonl`, `summary.json`, `sources.json`,
`environment.json`, `verification.json`, compiler/binary identities, exact staged
sources, and command logs. The summary includes per-variant medians and ranges
and paired changes. Existing output is never overwritten, completed observations
are not discarded, and failures retain their commands and diagnostics. CI checks
correctness and completion rather than imposing a noisy timing threshold.

### Supplemental evidence integrity

A supplemental Linux run produced a 456-observation in-memory summary, but its
persisted aggregate logs contained only 454 observations when audited. The two
missing rows are sample 5 of `sort-natural-reversed-10000`; both individual
command logs exist. The cause is undetermined. The
[unmodified incomplete evidence](evidence/linux-incomplete/provenance.json)
is retained for inspection and is excluded from performance conclusions.

The current Python runner additionally reads back `observations.jsonl` and
requires exact equality with completed observations before reporting success.
This check was added after the measurements; the original measured runner is
retained in the macOS evidence snapshot. The native result was independently
audited in full and has no missing observations.

## Scope and tradeoff

These are component timings for in-memory ordering and construction. They do
not measure complete folder-open latency, filesystem I/O, video decoding,
rendering, whole-player CPU use, or energy consumption. Results depend on the
host, compiler, and Foundation locale implementation.

Caching names adds O(n) temporary filename/record storage and a mapping pass.
It is a CPU tradeoff rather than a memory reduction. Tiny lists, already ordered
inputs, and path-heavy tie cases are included so their costs remain visible.
