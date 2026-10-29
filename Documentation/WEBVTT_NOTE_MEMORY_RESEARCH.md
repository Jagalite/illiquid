# Ignored WebVTT comment memory research

Date: 2026-10-28. Scope: the external text subtitle converter.

## Finding and change

The converter previously split every block into an array of lines before deciding
whether a WebVTT `NOTE` block should be ignored. A multiline comment therefore
created a temporary `Substring` entry for each line even though none of those
lines contributed to the converted ASS output. The loader accepts bounded files
up to 32 MiB (`SubtitlePipeline.Limits.externalSubtitleBytes`), so a permitted
comment-heavy file can still cause substantial transient allocation work. This
is transient memory amplification during import, not an accumulating leak.

The converter now checks the comment marker before constructing the line array.
Only blocks starting with ASCII `N` or LF enter the check. The LF case preserves
the extra empty first line left by odd-length newline separators. Ordinary timing
lines and numeric cue identifiers bypass the prefix checks. The accepted markers
remain exactly `NOTE`, `NOTE `, and `NOTE` followed by a tab on the first nonempty
line. Lookalike identifiers and cue payload text retain their existing behavior.

The block iterator still scans the input to find boundaries. Total comment
handling remains linear in input bytes; the improvement removes the per-line
array and its construction for ignored comments. No retained cache, source-size
limit, renderer behavior, or conversion error contract changes.

## Method and source provenance

The baseline is the complete converter at
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`, Git blob
`db1fe944a1de9a4feac565aab4f3dbf6ec472292`. This avoids attributing the repository's
previous parser optimizations to this change. The new `--baseline-ref` argument
resolves an immutable commit/blob and verifies its contents. The existing frozen
baseline and sixteen default workloads are preserved.

Both variants were built from their full production source as separate Swift
modules with Swift 6.3.2 on Linux x86_64, using `-O`, whole-module optimization,
Swift 6 language mode, and warnings as errors. Identical clients imported those
modules without cross-module optimization. All builds and runs were serialized;
Kyoto was unavailable on this host. This was a shared container, so small timing
differences require caution.

The final memory cohort contains six adjacent AB/BA pairs for each of eight cases:
96 fresh processes, one conversion each, with case order reversed each round.
Fixtures were written in bounded chunks before measurement. Each process measured
conversion time and captured peak RSS before writing its output. The runner
compared complete output bytes for every pair, checked error identities, and
retained all samples. The large-comment cases also had to match the single-cue
control's output. Full source/compiler/build hashes and fixture hashes are in
[the retained evidence](../Benchmarks/ExternalSubtitleMemory/evidence/webvtt-note-linux/README.md).

Peak RSS includes process startup, Swift/Foundation, input loading, and allocator
behavior. Preconversion high-water readings are retained, not subtracted. RSS is
not an allocation count or a precise count of freed bytes. The stress files use
16-byte nonblank comment lines; the near-limit file is exactly 33,553,408 bytes.
They demonstrate scaling within the accepted input bound, not typical file sizes.

## Final fresh-process results

| Workload | Peak RSS before / after (MiB) | Paired RSS change | Conversion before / after (ms) | Paired time change |
|---|---:|---:|---:|---:|
| 512 KiB comment + cue | 17.15 / 16.92 | -1.2% | 19.578 / 2.078 | -89.5% |
| 8 MiB comment + cue | 46.69 / 30.23 | -35.3% | 290.534 / 26.868 | -90.7% |
| 32 MiB minus 1 KiB, comment + cue | 112.74 / 78.27 | -30.6% | 1189.896 / 106.904 | -91.0% |
| 8 MiB comment, no cues | 46.59 / 30.20 | -35.1% | 290.252 / 27.173 | -90.8% |
| 2,000 short comments interleaved with cues | 16.97 / 16.98 | -0.0% | 22.266 / 20.734 | -7.8% |
| One ordinary cue | 16.52 / 16.54 | -0.2% | 0.322 / 0.337 | +3.8% |
| 2,000 ordinary WebVTT cues | 16.89 / 16.83 | -0.2% | 19.523 / 20.563 | +4.3% |
| 2,000 ordinary SRT cues | 16.82 / 16.79 | +0.2% | 18.372 / 18.440 | +0.0% |

Before/after columns show separate medians. Percentage columns show the median
of the six adjacent-pair ratios, so they need not equal a ratio of those medians.
No samples were discarded. The 512 KiB case is near the process memory floor;
its small RSS difference does not establish a useful memory saving at that size.
The 8 MiB and near-limit cases show the substantive memory reduction.

## Common-case cost and rejected prototype

An initial implementation ran the complete prefix check for every WebVTT block.
It achieved the large-comment benefit, but its ordinary 2,000-cue WebVTT control
was 14.1% slower by paired median. Its source and all 96 samples are retained in
`prototype`. The first-byte gate was added to avoid that work for ordinary cues.

The final fresh-process WebVTT control still measured +4.3% by paired median.
To investigate, the unchanged existing conversion benchmark driver was compiled
against the same already-built baseline/candidate modules. Eight adjacent AB/BA
pairs per workload used calibrated shared iteration counts targeting 200 ms.
This additional cohort contains 64 observations and measures warm complete
conversion throughput, not peak memory:

| Warm conversion workload | Wall time change | CPU time change |
|---|---:|---:|
| `vtt-2000-plain` | +3.36% | +3.52% |
| `vtt-10000-plain` | +0.22% | +0.27% |
| `vtt-2000-multilingual` | -6.00% | -6.33% |
| `srt-2000-plain` | +3.66% | +3.65% |

For the 2,000-cue plain WebVTT case, pair ratios ranged from 0.920 to 1.095, with
five of eight above one. The larger plain WebVTT case was approximately flat by
paired median, and the unchanged SRT control moved similarly to the smaller
plain WebVTT case. These results do not establish a general common-cue regression
or speedup. A small overhead remains possible. The change is supported by the
large ignored-comment memory reduction; it does not claim faster conversion for
all files. Warm controls use the existing driver's longer payloads and cue
identifiers, so their absolute timings differ from the fresh-process fixtures.

## Correctness and qualification

- Final converter: 36 tests in two suites pass in debug and release, with warnings
  as errors. The same final tests also pass against the unchanged baseline in
  release, checking that the expected behavior predates this optimization.
- New cases cover exact and near-matching markers, ASCII and Unicode lookalikes,
  leading LF, BOM, LF/CRLF/CR normalization, timing-looking comments, `NOTE` in
  payload text, and a 50,000-line comment followed by a valid cue.
- The unchanged differential driver confirms exact UTF-8 output and typed-error
  equality for all 1,698 cases, including Unicode and escape boundaries.
- Both fresh-process cohorts and the warm-control cohort pass their output/error,
  result-consumption, ordering, and sample-count checks.
- Independent source review found no blocking semantic or measurement issue.

These results qualify the Foundation-only converter on Linux. They do not
qualify the full macOS application, AppKit, libass, rendering, live playback,
whole-player RAM, energy, or UI responsiveness. The existing macOS 26 workflow
now runs the targeted NOTE cohort against the pinned pre-change converter and
uploads its receipts. Its result is tracked on the PR; this report does not
claim that native CI or live playback has passed.

## Reproduce

Use the repository's Kyoto queue when available, as required by `AGENTS.md`.
Otherwise state its absence and run builds serially. Use Python 3.11 or newer
and an appropriate Swift compiler. In a shallow checkout, fetch the baseline
commit before running:

```sh
git fetch --no-tags --depth=1 origin ea2ff568237e2667f7b1aeee67b11a44ebe95b72
bash Scripts/test-external-subtitle-regressions.sh -c debug -Xswiftc -warnings-as-errors
bash Scripts/test-external-subtitle-regressions.sh -c release -Xswiftc -warnings-as-errors
python3 Benchmarks/ExternalSubtitleMemory/run.py benchmark \
  --baseline-ref ea2ff568237e2667f7b1aeee67b11a44ebe95b72 \
  --rounds 6 --case vtt-note-512k --case vtt-note-8m \
  --case vtt-note-near-limit --case vtt-note-only \
  --case vtt-note-interleaved --case vtt-note-control \
  --case vtt-2000 --case srt-2000 \
  --output /tmp/webvtt-note-memory
python3 Benchmarks/ExternalSubtitleMemory/run.py summarize \
  --output /tmp/webvtt-note-memory
```

Select a compiler with `--swiftc /path/to/swiftc` or `SWIFTC`. The common-control
execution snapshot records how the unchanged conversion driver and verifier
were reused with the measured modules; its temporary paths need remapping for
another machine. Full raw observations, summaries, manifests, snapshots, and
passing test logs are retained with this change.
