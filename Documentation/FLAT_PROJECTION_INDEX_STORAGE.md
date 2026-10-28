# Flat projection: reuse the existing sort permutation

## Problem and scope

Files Only and Media projection sort discovered file entries before deduplicating
paths and constructing display rows. The sorter already sorts integer positions
to avoid moving metadata during comparisons, then materializes a complete
`[SourceTreeEntry]`. The flat projection immediately consumes that array with
`compactMap`, producing a second array of display rows.

The intermediate entry array is unnecessary for this caller. Entry values
contain reference-backed fields, so this is a shallow value-buffer copy, not
a deep duplication of every string or metadata payload.

This study compares main revision
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72` against implementation
`d31ed9a65523416c330a9702198c06fe446f74b5`.
It measures complete production `rows()` calls after fixture setup.

## Implementation

`SourceTreeSorting.sortedIndicesIfNeeded` exposes the permutation already
computed by the existing sorter. Its filename cache, comparator, criterion
precedence, missing-date handling, literal path tie breaker, and original-index
tie breaker are unchanged. The existing `sorted` API remains available and
maps that permutation back into entry values for other callers.

Flat projection now maps the permutation directly into final display rows.
Its row-construction body is unchanged apart from extracting a local helper.
Sorting still completes before the shared path-deduplication set is populated,
so repeated paths retain the first payload under the selected sort order.

The helper returns `nil` when all criteria are disabled or there are fewer
than two entries. Those cases use direct iteration of the input; they allocate
neither a sort permutation nor a sorted-entry buffer. The implementation adds
no cache or retained application state.

## Qualification design

The existing FlatFileProjection component harness stages complete production
projection files and guarded, verbatim Foundation declarations from the larger
UI files. Baseline and candidate compile into separate library/executable
targets. The new `--include-sorter` mode keeps both focal implementations at
their respective revisions and rejects any difference in surrounding Sidebar
declarations. Shared supporting sources, test files, harness, and package
settings are identical within each cohort and retained with SHA-256 receipts.

Four existing suites run against baseline and candidate in both debug and
release on macOS:

- `SourceBrowserFilterTests`
- `SourceMediaOrganizationTests`
- `FlatFileProjectionTests`
- `SourceTreeSortingTests`

The sorter suite covers all 27 configurations, full ties, metadata preservation,
natural name ordering, missing dates, and empty/singleton inputs. Projection
tests cover both view modes, duplicate explicit/discovered paths, selected
metadata precedence, Unicode aliases, retained recursive snapshots, and
cancellation.

The measurement matrix has 10,000 entries in each of six source/view scenarios:
folder-only, mixed folder/explicit files, and explicit files only, each in
Files Only and Media views. Each runs ascending-name, descending-creation-date,
and all-off sort configurations: 18 cells. Before sampling, every complete row
trace is compared between variants, including URL representation, recognition,
dates, visibility, context, and order.

Native timing uses six balanced AB/BA pairs per cell, fresh processes, two
warmups, identical iteration counts, and separate wall/CPU clocks. No samples
are removed. The separate Linux/glibc allocation cohort uses two balanced pairs
and one measured call per process. Linux runs complete output parity but skips
the regression suites with `--mode benchmark`.

The allocation interceptor counts successful intercepted malloc/calloc/realloc
requests and requested bytes only while `rows()` executes. Fixture generation,
result consumption, and returned-row destruction are outside the interval.
Instrumented timings are excluded from native speed conclusions.

## Results

### Confirmed allocation result

The Linux allocation job completed successfully. All 18 full-row comparisons
matched, and all 72 observations were retained. Every one of the 24 sorted
baseline/candidate pairs requested fewer allocation bytes.

The median saving was **2,400,032–2,401,568 requested bytes per rebuild** for the
12 sorted cells at 10,000 entries. This is approximately **2.4 MB (2.29 MiB)**
less allocation traffic, or **1.70–4.73%** of all requested bytes during the
complete projection operation.

| Source / view | Sort | Baseline MB requested | Candidate MB requested | Bytes saved | Paired reduction |
| --- | --- | ---: | ---: | ---: | ---: |
| Folders / Files Only | Name ascending | 80.086 | 77.686 | 2,400,032 | 3.00% |
| Folders / Files Only | Date descending | 50.755 | 48.355 | 2,400,032 | 4.73% |
| Folders / Media | Name ascending | 85.242 | 82.842 | 2,400,128 | 2.82% |
| Folders / Media | Date descending | 55.912 | 53.512 | 2,400,128 | 4.29% |
| Mixed / Files Only | Name ascending | 108.499 | 106.097 | 2,401,448 | 2.21% |
| Mixed / Files Only | Date descending | 79.154 | 76.753 | 2,401,496 | 3.03% |
| Mixed / Media | Name ascending | 113.668 | 111.266 | 2,401,568 | 2.11% |
| Mixed / Media | Date descending | 84.323 | 81.922 | 2,401,448 | 2.85% |
| Explicit files / Files Only | Name ascending | 141.134 | 138.733 | 2,400,752 | 1.70% |
| Explicit files / Files Only | Date descending | 111.786 | 109.385 | 2,400,800 | 2.15% |
| Explicit files / Media | Name ascending | 130.210 | 127.810 | 2,400,032 | 1.84% |
| Explicit files / Media | Date descending | 100.879 | 98.479 | 2,400,032 | 2.38% |

MB is decimal (1,000,000 bytes). Values are separate medians; percentages are
medians of within-pair reductions. The benchmark's raw
`median_paired_change_percent` uses the opposite sign: negative means lower.

The all-off sort control had exactly equal median request bytes in five of six
scenarios. Explicit Files Only differed by just 48 bytes out of approximately
109.3 MB. These controls show no proportional allocation cost added to the measured no-sort workloads.

On this Linux toolchain, `SourceTreeEntry` stride was 240 bytes and an index was
8 bytes. For folder-only Files Only, the 2,400,032-byte saving is consistent with
removing the 10,000-entry buffer and its header. This is an interpretation of the
observed allocation delta, not a peak-memory measurement.

The source receipt audit confirms that only the two expected staged focal
sources differ. All surrounding Sidebar declarations passed the exact-byte gate.
An independent recomputation from raw observations reproduces every request/
byte median and paired percentage, checks the balanced AB/BA order and output
checksums, and verifies equal full-trace hashes.

### Native qualification remains pending

At the latest status check, the macOS job was still queued. No native regression
test result or native timing result is claimed in this report. The implemented
change is proposed as a **draft PR** until the macOS regression and timing
qualification can be reviewed. The allocation result is a completed finding;
it does not establish a macOS speedup.

The Linux `--mode benchmark` run compiled both complete component variants and
performed full trace parity, but did not run the four regression suites.


## Evidence and reproduction

- [Qualification run 40637605269](https://github.com/Jagalite/illiquid/actions/runs/40637605269)
- [Successful Linux allocation job](https://github.com/Jagalite/illiquid/actions/runs/40637605269/job/122648063951)
- [Queued macOS regression/timing job](https://github.com/Jagalite/illiquid/actions/runs/40637605269/job/122648063675)
- [Retained raw allocation observations and receipts](../Benchmarks/FlatFileProjection/IndexStorageEvidence/linux-allocations.json)
- [Independent arithmetic and receipt audit](../Benchmarks/FlatFileProjection/IndexStorageEvidence/allocation-audit.json)

The Linux cohort used Swift 6.4, x86_64, glibc 2.39, with the process pinned to CPU
0 on the hosted runner. The complete generated sources, full row traces, build
logs, and binaries are also retained in the run's
`flat-file-projection-allocations-linux` artifact (14-day retention). The
checked-in JSON keeps the raw measurements, full-trace hashes, environment,
source/binary hashes, summaries, and completion marker after that artifact
expires.

```sh
python3 Benchmarks/FlatFileProjection/run.py \
  --baseline ea2ff568237e2667f7b1aeee67b11a44ebe95b72 \
  --current-support --include-sorter --sizes 10000 --sorts name date off \
  --pairs 6 --target-ms 120 --output /tmp/flat-projection-index-timing

python3 Benchmarks/FlatFileProjection/run.py \
  --baseline ea2ff568237e2667f7b1aeee67b11a44ebe95b72 \
  --current-support --include-sorter --sizes 10000 --sorts name date off \
  --mode benchmark --allocations --pairs 2 \
  --output /tmp/flat-projection-index-allocations
```

Run builds through Kyoto where available, as required by AGENTS.md. The hosted
CI jobs record that Kyoto is unavailable before compiling serially in isolated
temporary packages.

## Limits

These are synthetic component workloads, not observations of a user's library.
The measured entry point includes merging, sorting, deduplication, URL handling,
metadata/context construction, and final row construction. It excludes disk
scanning, UI delivery/rendering, and media decoding/playback.

Requested allocation bytes are allocation traffic, not live or peak heap and
not whole-player RSS. Linux allocation figures do not establish a macOS
footprint reduction. A smaller temporary entry buffer has a direct source-level
mechanism, but any native peak-memory claim would require separate measurement.

Full-app/native integration and live UI/playback qualification are not completed by this study. The PR's existing integration workflows remain required before treating the change as ready to merge.
