# Fuzzy subtitle prefix scoring

## Research question

Can complete external-subtitle association avoid copying shared filename tokens
for every fuzzy candidate while preserving scores, ambiguity, ordering, and cancellation?

The production change passes the existing prefix directly to the generic
`tokenWeight` helper. It replaces `Array(mediaTokens.prefix(sharedCount))` with
`mediaTokens.prefix(sharedCount)`; no slice escapes and no scoring rules change.

## Reproduce

```sh
python3 Benchmarks/SubtitleFuzzyPrefix/run.py --pairs 16 --target-ms 250 --output /tmp/subtitle-fuzzy-prefix
```

Use the repository's Kyoto queue for builds when it is available. The runner
serializes builds in isolated temporary packages and needs Swift 6.1 or newer
plus the baseline commit in local Git history. No external Swift dependencies
or FFmpeg installation are needed for this component benchmark.

## Method

The baseline is the complete production implementation at
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`. Separate optimized modules contain the
baseline or candidate matcher and its two unmodified production dependencies.
The same five existing subtitle regression suites run against each implementation
in debug and release with warnings treated as errors.

Timing covers complete association calls, result consumption, and result destruction.
It excludes URL construction, fixture verification, warmup, and process startup.
Each sample is a new process. Sixteen pairs alternate baseline/candidate and
candidate/baseline order, with identical iteration counts calibrated to roughly
250 ms of CPU time and a minimum of five associations per sample.

The fixture generator supplies independent complete-output oracles; each is
checked with forward and reversed inputs. Cases include generic-prefix ambiguity,
a unique fuzzy winner, ASCII and Unicode titles, longer prefixes, exact matches,
unrelated files, empty inventories, release-specific matching, duplicate inputs,
and the minimum shared-prefix weight.

Source, test, compiler, fixture, binary, and command receipts are retained together
with all observations. Paired ratios and descriptive bootstrap intervals summarize
the recorded run; they are not estimates across a population of computers.

## Results and limits

The investigation is awaiting its first macOS CI measurement. Results will be
recorded here after qualification. The removed source-level array is a transient
scoring buffer; this benchmark does not count allocations or measure retained heap.
It also does not measure full-player startup, decoding, UI responsiveness, or playback.
