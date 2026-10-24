# Media section projection memory

## Problem and change

The media browser organizes filtered rows into movie, TV, extra, and other-video
sections on every media-view projection. The former implementation grouped full
`SourceTreeDisplayRow` values. Episode sections then created enumerated row
buffers, sorted those values, and mapped them into another row array before
appending them to the returned projection. These temporary arrays coexist with
the source rows, visibility cache, and an output the caller may still display.

`SourceBrowserFilter.organizeMedia` now groups original row indices, sorts those
indices for episode sections, and appends each full row directly into one final
array. That final array reserves `rows.count + sections.count` entries: exactly
one entry per input row plus one header per section. A cancellation check before
the reservation avoids this allocation when cancellation arrived during grouping.

The implementation remains private to the media browser. There are no new
dependencies, persistence changes, or public APIs.

## Behavior preserved

Section-title folding still runs in input order and retains the first canonical
spelling, including the existing UTF-8 guard for canonically equivalent inputs.
Section rank and localized comparison are unchanged. Each section header still
uses its first input member's URL, before episode sorting.

Within a section, increasing original indices have the same relative order as
the former section-local enumeration offsets. Episode number and air-date
comparisons therefore retain their previous tie ordering, including alternate
versions and duplicate rows. Movies, extras, and unknown files keep their input
order. All row fields are copied intact into the output.

The existing localized section comparator has no secondary tie-break for
distinct titles that collate equally. This change preserves that behavior.
Existing Unicode tests compare membership independently of those collation ties;
benchmark fixtures use section names with unambiguous relative order.

Three additional regression tests cover searched rows with gaps, repeated
episode variants, visibility badges, exact header spelling and URL, missing
recognition, source replacement with an earlier projection still retained, and
deterministic cancellation before actor entry.

## Experiment

The focal baseline is commit
`6f70cd2446fc6ef38d4e5a0fbf96f91b2234e635`. The benchmark compiles the complete
production projection file and the same production support types for both
variants. The existing source-tree snapshot helper records every extracted
declaration and source hash. Linux changes only the documented POSIX/XML import
boundaries and one directory-URL hint in a pre-existing test fixture.

The main cohort covers eight shapes at 1,000 and 10,000 inputs: movies, seasons,
Unicode groups, one section per item, broad search, narrow search, files-only
view, and tree view. The stress cohort adds movies and seasons at 50,000 inputs.
Each case has a cold first projection and a cached refresh measurement, with
six balanced AB/BA pairs of fresh processes per measurement. Refresh performs
one untimed priming call and three measured calls, explicitly retaining the
preceding output until its replacement has returned.

Peak RSS is sampled immediately before and after the measured calls. Only after
the final sample does the process allocate a complete output trace, load the
baseline oracle, compare sorted-key JSON bytes, and encode its report. Separate
verification processes also compare full baseline/candidate output bytes.

The main cohort runs the browser filtering, search, organization, grouping, and
new regression tests against both variants in debug and release, treating
warnings as errors. Source and staged-source hashes are checked again after
measurement. The stress cohort must use identical source and harness hashes.

## Native macOS results

[Native workflow 40101170623](https://github.com/Jagalite/illiquid/actions/runs/40101170623)
succeeded on the measured code commit `114495895a2af089ea9ef488c02726346a5ae476`.
The host was **Apple M1 (Virtual), 3 CPUs, macOS 26.6.2, Apple Swift 6.3.3**,
using Xcode 26.6 selected by the workflow. Both cohorts used current-support
mode with identical support sources and identical staged source hashes across
cohorts. All supplied sources match the proposed change.

| Workload | Items | Mode | Baseline peak MiB | Candidate peak MiB | Median paired change | Lower-RSS pairs |
|---|---:|---|---:|---:|---:|---:|
| Movies | 1,000 | refresh | 11.750 | 11.234 | -4.39% | 6/6 |
| Episodes across seasons | 1,000 | refresh | 15.281 | 12.891 | -15.64% | 6/6 |
| Movies | 10,000 | refresh | 48.047 | 44.406 | -7.58% | 6/6 |
| Episodes across seasons | 10,000 | refresh | 57.422 | 49.094 | -14.50% | 6/6 |
| Unicode section names | 10,000 | refresh | 58.680 | 49.969 | -14.86% | 6/6 |
| One section per item | 10,000 | refresh | 74.781 | 63.109 | -15.61% | 6/6 |
| Broad search | 10,000 | refresh | 61.016 | 54.234 | -11.11% | 6/6 |
| Narrow search | 10,000 | refresh | 40.844 | 40.664 | -0.44% | 6/6 |
| Files-only control | 10,000 | refresh | 40.344 | 40.391 | +0.12% | 0/6 |
| Tree-view control | 10,000 | refresh | 39.000 | 39.047 | +0.12% | 0/6 |
| Movies | 50,000 | cold | 180.734 | 164.406 | -9.03% | 6/6 |
| Movies | 50,000 | refresh | 203.688 | 186.375 | -8.50% | 6/6 |
| Episodes across seasons | 50,000 | cold | 201.734 | 182.305 | -9.63% | 6/6 |
| Episodes across seasons | 50,000 | refresh | 226.984 | 205.078 | -9.65% | 6/6 |

Absolute columns are separate per-variant medians. Percentages are medians of
six paired percentage changes, so they need not equal the ratio of the displayed
medians. Negative values mean a lower peak. All observations, including adverse
controls, remain in the checked-in receipts.

At 10,000 items, the five workloads that build large sections lower peak RSS in
all six pairs in both modes, with paired reductions of **7.18–18.16%**. The
18.16% case is the first projection of one section per item: 65.312 to 53.453 MiB.
The 50,000-item cases improve in all six pairs, by **8.50–9.65%**. The large
season refresh reduces the separate median peaks by **21.906 MiB**.
Files-only and tree-view control peaks are slightly higher (about 0.12%, or
48 KiB at 10,000 items); the 10,000-item narrow-search peaks change by less than 0.5%.

The measured layout is 320 bytes per display-row value versus 8 bytes per index.
This explains why the intermediate arrays are smaller; it is not a measurement
of heap savings per row or a 40-fold reduction in process memory.

### Timing and trade-offs

Episode refreshes also improve in all six wall/CPU-time pairs. At 10,000 items,
separate median wall times are 222.731 to 65.201 ms per call, with a median paired
change of −72.94%; at 50,000 they are 1,190.938 to 283.128 ms, with a paired
change of −76.90%. These are complete cached projection calls, not frame times.

Timing does not improve universally. The 10,000-movie cold case is **7.39%
slower** by median paired wall time, with all six pairs slower (separate medians
155.498 to 183.420 ms), despite its 7.18% memory reduction. The tree-refresh
control has a +29.69% paired wall change while both separate medians round to
0.040 ms. Such very short control samples are noisy; all raw times are retained.
The change is justified by lower section-projection peak memory, with these
latency trade-offs made explicit.

### Correctness and evidence audit

- 33 tests pass for each baseline/candidate × debug/release combination.
- All 18 separate full projection datasets match byte for byte.
- All 432 measured outputs match the complete baseline JSON bytes after memory
  sampling: 384 main observations and 48 stress observations, with no exclusions.
- The independent audit recomputes every summary statistic and verifies all
  216 pairs, their balanced order, 980 stdout/stderr hashes, and 76 staged files
  across the two variants and two cohorts.
- Proposed source, test, harness, runner, and extracted-source hashes match the
  evidence; both cohorts use identical staged source hashes.

The workflow intentionally excludes compiled binaries from its uploaded artifact.
The audit checks all supplied logs, source copies, traces and receipts; it cannot
rehash omitted executable bytes. This is a native component qualification,
not an interactive whole-player or full application-graph test.

## Interpretation

These are component-process peak RSS measurements, including the Swift runtime,
fixtures, actor caches, and returned projections. Refresh peaks also include the
priming call. Subtracting the before/after high-water marks does not measure live
heap or bytes allocated. Neither the memory figures nor component timings are
whole-player measurements.

Inputs are synthetic local URLs with actual precomputed recognition. The
measured projection performs no media reads. The study does not measure decoding,
video buffers, SwiftUI drawing, scrolling, energy, or playback FPS. Benefits
should be interpreted in the context of large media-library projections.

Elapsed and process CPU times cover the awaited projection calls and small
measurement receipts. They are reported separately from memory; a smaller peak
does not establish a speedup for every workload. Files-only/tree views and
narrow searches serve as controls for work that does not build large section
buffers.

## Reproduction and evidence

See [the benchmark guide](../Benchmarks/MediaSectionMemory/README.md) for commands
and output definitions. The native workflow is
[media-section-memory.yml](../.github/workflows/media-section-memory.yml).
Its current-support mode compiles both focal variants with identical current
support sources; strict local studies require every support source to match
the pinned baseline. Receipts identify the mode used for each recorded cohort.

An earlier Linux study completed, but its raw receipts were lost when the
temporary execution environment was replaced before publication. Its retained
summary is not used as the final evidence. The completed native study above is the authoritative qualification. The
interrupted Linux recovery was superseded after native qualification succeeded;
none of its partial observations enter the reported results.
