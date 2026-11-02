# External subtitle conversion peak memory

This component study compares the complete production
`ExternalTextSubtitleConverter` with the frozen source from `main` at
`af1c1ad` by default. `--baseline-ref` selects the converter at another locally
available Git commit/ref and resolves it once to an immutable commit and blob.
The baseline manifest records its full Git revision, original path, Git blob,
and SHA-256; the runner verifies the source against that manifest. Each variant
is a separately optimized Swift module. An identical driver imports it with
`@testable import`; no replacement parser or cross-module optimization is used.

## Reproduce

```sh
python3 Benchmarks/ExternalSubtitleMemory/run.py benchmark \
  --rounds 6 --output /tmp/external-subtitle-memory
python3 Benchmarks/ExternalSubtitleMemory/run.py summarize \
  --output /tmp/external-subtitle-memory
```

Use Python 3.11 or newer. Select Swift with `--swiftc /path/to/swiftc` or `SWIFTC`. The converter needs
Foundation only; it does not require the native playback SDK. macOS builds use
the repository's macOS 26 deployment target. `benchmark` requires a new/empty
output directory; `summarize` rechecks an existing completed cohort. For a
short smoke check use `--rounds 2 --case srt-2000 --case vtt-malformed`.

## Ignored WebVTT NOTE blocks

See [the NOTE research report](../../Documentation/WEBVTT_NOTE_MEMORY_RESEARCH.md)
for measured results, controls, and qualification limits.

The six opt-in NOTE cases compare early comment rejection against the converter
immediately before that change. The original frozen baseline and sixteen default
cases remain available. Fetch the pinned commit first if using a shallow checkout:

```sh
python3 Benchmarks/ExternalSubtitleMemory/run.py benchmark \
  --baseline-ref ea2ff568237e2667f7b1aeee67b11a44ebe95b72 \
  --rounds 6 --case vtt-note-512k --case vtt-note-8m \
  --case vtt-note-near-limit --case vtt-note-only \
  --case vtt-note-interleaved --case vtt-note-control \
  --case vtt-2000 --case srt-2000 \
  --output /tmp/webvtt-note-memory
```

`vtt-note-512k`, `vtt-note-8m`, and `vtt-note-near-limit` contain one comment
with nonblank 16-byte lines followed by the same valid cue. Complete input sizes
are exactly 512 KiB, 8 MiB, and 32 MiB minus 1 KiB. The runner writes at most
64 KiB per chunk and compares the output receipts across these cases and the
single-cue `vtt-note-control`. `vtt-note-only` is an 8 MiB comment without a cue
and must report `noValidCues(webVTT)`. `vtt-note-interleaved` inserts a small
comment before each of 2,000 ordinary cues, checking overhead outside a single
large block. The plain WebVTT and SRT cases serve as unchanged-work controls.
These synthetic comment sizes are stress cases, not typical subtitle sizes.

## Fixtures and measurement

Sixteen synthetic cases cover both SRT and WebVTT: 2,000, 50,000, and 200,000
short cues; 2,000 cues with approximately 8 KiB ASCII payloads; 2,000 cues with
approximately 8 KiB multilingual payloads containing combining marks, emoji,
and ASS escapes; 50,000 CRLF cues; 50,000 malformed cues producing the
expected typed conversion error; and 2 MiB of leading LF bytes followed by one
valid cue (after the signature block for WebVTT). The last case checks the
array cost of many empty blocks without substantial retained cue payload.
Python generates all input files before any measurements. The runner checks
that every input and successful ASS output fits the production 32 MiB bound.
The larger cases are stress workloads, not claims about typical subtitle size.

Each observation launches a new process, loads its input, and converts it
**once**. There is no warm conversion. It records monotonic elapsed and process
CPU time around conversion. Immediately afterward, `getrusage(RUSAGE_SELF)`
captures the process peak resident set before output encoding, file writing,
hashing, or result serialization. Darwin reports bytes; Linux KiB are converted
to bytes. The returned ASS String and loaded input are alive at capture.

Peak RSS includes Swift/Foundation startup, input loading, allocator behavior,
and conversion. Linux can also retain a launcher's high-water RSS floor. The
runner streams fixture generation and file hashing to keep its own footprint
small. Pre-conversion peak RSS is retained as a diagnostic, not subtracted.
Peak RSS is not an allocation count or a precise allocation delta.
Timing excludes file loading and output writing; RSS cannot subtract those
earlier process peaks. Results concern the converter, not whole-player memory,
libass, rendering, UI responsiveness, playback throughput, or energy.

Default measurements run serially with six adjacent baseline/candidate pairs
per case, alternating AB and BA; case traversal also reverses each round.
Every sample is retained. Use an otherwise idle host without concurrent builds
or benchmarks. There are no noisy percentage thresholds in CI.

After the RSS capture, each process writes its complete output. Python compares
baseline/candidate files byte-for-byte for every pair and checks typed errors,
sizes, and SHA-256 receipts across the entire cohort. One compressed exact
output per valid fixture is retained. The runner records original process
stdout, command logs, source snapshots, source/compiler/library/binary hashes,
raw observations, medians, ranges, and each paired ratio and difference.

Build products, module caches, and generated fixture files belong in the run
directory, not source control. Curated evidence can retain manifests, raw
observations, summaries, process logs, and compressed output receipts. Dedicated
semantic tests separately exercise delimiters, Unicode, malformed timestamps,
escaping, and parser compatibility; these sixteen memory workloads do not
replace that coverage.

## Recorded results

See [the research report](../../Documentation/EXTERNAL_SUBTITLE_MEMORY_PERFORMANCE.md)
for the complete Linux result table and native qualification limits. Curated
evidence under `evidence/linux` retains all measurements, original process
receipts, command/source hashes, source snapshots, and passing test logs.
