# Media section projection memory

This benchmark compares complete `SourceBrowserFilter.project(input:)` calls
before and after replacing full-row grouping/sorting buffers with row indices.
The baseline is `6f70cd2446fc6ef38d4e5a0fbf96f91b2234e635`; the candidate is the
current working tree. The production projection file is compiled unchanged.
The source snapshot helper used by the existing source-tree and section-grouping
benchmarks supplies the remaining production types and records its extraction
boundaries. Every support source must match between the two variants.

## Run

Requires Swift 6.1 or newer and Python 3. No media, network service, FFmpeg, or
third-party package download is needed. Use a new output directory for each run.

```sh
python3 Benchmarks/MediaSectionMemory/run.py --output /tmp/media-section-memory
python3 Benchmarks/MediaSectionMemory/run.py --mode benchmark --pairs 6 \
  --cases movies seasons --sizes 50000 --output /tmp/media-section-memory-stress
```

The default runs the existing browser filtering, search, media organization, and
grouping tests plus the new storage regression tests in debug and release for
both variants. It then verifies full serialized projection output and measures
six balanced baseline/candidate pairs in fresh processes for every workload at
1,000 and 10,000 input items. The second command adds 50,000-item movie and
episode stress cases without repeating the tests.
`--mode tests`, `--mode verify`, and `--mode benchmark` select individual phases;
`--cases`, `--sizes`, and `--measurements` select workloads. Exploratory runs
should also pass `--smoke`.

By default, support files must match the pinned baseline exactly. CI passes
`--current-support` to compare the historical projection implementation with
the candidate using the same current support sources on both sides; source
receipts identify that mode explicitly. This allows unrelated support updates
to participate in ongoing regression coverage without silently changing a
historical measurement.

## What is measured

- **Cold:** one first projection on a fresh actor, after constructing its inputs.
- **Refresh:** one untimed priming projection followed by three cached
  projections. The preceding result remains alive until its replacement returns,
  matching a caller that still displays its current rows.
- **Memory:** `getrusage` process peak RSS immediately before and after the
  projection calls. Trace construction, expected-output loading, comparison, and
  JSON reporting all happen after the final memory sample.
- **Time:** elapsed and process CPU time around the awaited calls, small output
  receipts, and final memory sample. Fixture creation and validation are excluded.

Peak RSS includes the Swift runtime, generated inputs, actor caches, and returned
rows. Refresh peaks also include priming. It is not whole-player memory, live
allocation size, or an allocation count. The difference between two high-water
marks is reported for inspection only; it is not an estimate of allocated bytes.
Times for cold and refresh calls describe different work and must be compared
within their own cohorts.

The fixtures use synthetic local URLs and actual media-name recognition, with
no media reads during projection. Files-only and tree views are unchanged
controls. Unique sections, where each item has its own header, exercise the
opposite shape from large shared sections. This does not measure SwiftUI drawing,
scrolling, decoding, playback, or a representative user's library.

## Evidence

The runner retains source and compiler receipts, staged source hashes,
executables' hashes, test logs, full comparison traces, raw paired observations,
summaries, and a completion marker. It fails if compared outputs differ or if
production, test, harness, or staged source bytes change during the run.
The checked-in evidence keeps compact receipts and observations; temporary build
trees and large generated traces can be reproduced with the command above.

See [the research report](../../Documentation/MEDIA_SECTION_MEMORY_PERFORMANCE.md)
for results, the exact measured protocol, and platform limitations.
