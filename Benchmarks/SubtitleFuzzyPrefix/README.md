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
unrelated files, empty subtitle input, release-specific matching, duplicate inputs,
and the minimum shared-prefix weight.

Source, test, compiler, fixture, binary, and command receipts are retained together
with all observations. Paired ratios and descriptive bootstrap intervals summarize
the recorded run; they are not estimates across a population of computers.

## Results

Qualified by [macOS CI run 40633636333](https://github.com/Jagalite/illiquid/actions/runs/40633636333)
on 2026-10-28: macOS 26.6.2, arm64, Apple Swift 6.3.3, with the workflow's
Xcode 26.6 toolchain. The measured candidate is
`a0eac866515f9190a37bab221c5d76fe58cc0185`; subsequent evidence/documentation
commits leave the measured production, test, runner, and driver files unchanged.

The eight-language ASCII fuzzy cases used **10.6–11.5% less process CPU time**
per complete association, based on median paired candidate/baseline ratios.
The long-prefix case used 10.8% less, Unicode 5.7% less, and the unique fuzzy
winner 9.6% less. Single-subtitle fuzzy cases showed smaller 1.7–2.2% reductions.
The unchanged exact, unrelated, and empty-subtitle controls stayed near parity:
their paired medians were within 0.6% of 1.0 and their intervals included 1.0.

All measured cohorts are shown below. Times are independently calculated variant
medians in milliseconds; the ratio is the median of the 16 per-pair ratios, so
it need not equal the ratio of the two displayed medians. Ratios below 1 favor
the candidate. Intervals are descriptive 95% paired bootstrap intervals.

| Complete association workload | Baseline CPU ms | Candidate CPU ms | Paired ratio | Ratio interval |
| --- | ---: | ---: | ---: | --- |
| 1 media file, 1 generic subtitle | 0.0100 | 0.0098 | 0.9813 | [0.9693, 0.9866] |
| 16 media files, 1 generic subtitle | 0.0917 | 0.0895 | 0.9779 | [0.9661, 0.9838] |
| 256 media files, 1 generic subtitle | 1.3837 | 1.3648 | 0.9823 | [0.9674, 0.9982] |
| 4,096 media files, 1 generic subtitle | 23.0598 | 22.6547 | 0.9830 | [0.9714, 0.9945] |
| 256 media files, 8 language variants | 1.8872 | 1.6907 | 0.8943 | [0.8877, 0.8990] |
| 4,096 media files, 8 language variants | 30.9131 | 27.3106 | 0.8854 | [0.8761, 0.9184] |
| 256 media files, long prefix, 8 languages | 2.3488 | 2.0868 | 0.8923 | [0.8785, 0.8977] |
| 256 media files, Unicode prefix, 8 languages | 3.3445 | 3.1463 | 0.9434 | [0.9339, 0.9575] |
| 256 media files, unique fuzzy winner, 8 languages | 1.9849 | 1.7883 | 0.9040 | [0.8956, 0.9119] |
| 256 media files, 256 exact subtitles | 2.3791 | 2.3782 | 1.0033 | [0.9975, 1.0313] |
| 4,096 media files, 4,096 exact subtitles | 38.8348 | 38.6419 | 0.9943 | [0.9804, 1.0118] |
| 256 media files, 256 unrelated subtitles | 1.8426 | 1.8415 | 1.0052 | [0.9900, 1.0247] |
| 256 media files, no subtitles | 0.0898 | 0.0900 | 1.0022 | [0.9944, 1.0066] |

Elapsed-time results tell the same story: the two eight-language ASCII fuzzy
cases had median paired ratios of 0.8938 and 0.8855. Both clocks and every sample
are retained in the evidence; no samples were discarded. This was one planned
run, not a best result selected from repeated benchmark attempts.

## Correctness and evidence

- All **43 existing tests in five suites** passed for baseline and candidate in
  both debug and release (four successful suite runs), with warnings as errors.
- All **19 independent fixtures** passed full mapping equality in both input
  orders for both implementations. Each timed process also checked its full
  mapping before measurement and consumed a verified checksum during timing.
- All **416 timed samples** completed: 13 workloads × 16 pairs × 2 variants.
- The recorded [production diff](evidence/macos-arm64/production.diff) contains
  exactly the intended replacement; the two dependency source blobs are identical.

Retained records:

- [Summary](evidence/macos-arm64/summary.json) and
  [all observations](evidence/macos-arm64/observations.jsonl).
- [Source/compiler/binary manifest](evidence/macos-arm64/manifest.json) and
  [calibration](evidence/macos-arm64/calibration.json).
- [Test receipts](evidence/macos-arm64/tests.json), the adjacent four complete
  test logs, [fixture parity](evidence/macos-arm64/parity.json), and
  [completion](evidence/macos-arm64/completion.json).
- [CI provenance](evidence/macos-arm64/provenance.json). The workflow artifact
  additionally includes exact fixture JSON, staged source packages, runner/driver
  snapshots, and command receipts. The fixture generator is deterministic and
  its serialized output hash is recorded in the manifest.

## Interpretation and limits

Generic title-prefix subtitles cause the matcher to compare one subtitle against
many related media names before deciding whether a unique winner exists. Avoiding
the temporary array reduces work in that scoring branch. The larger reduction
with eight subtitle language variants is consistent with repeating that branch
more often relative to filename tokenization and media-index construction.

These are synthetic, repeatable folder inventories exercising the complete
production component, not recorded user-library traces. Broad generic prefixes
are intentionally stressed; ordinary exact matches bypass the changed line and
show no established gain. A 4,096-file case is a scaling workload, not a claim
about the user's typical folder size.

The removed source-level array is transient scoring storage. This experiment
does **not** count heap allocations or establish a retained-memory/RSS reduction;
compiler optimizations and slice-to-array storage reuse can vary by input and
toolchain. No full-player startup, UI, decoding, playback, or live rendering
performance claim follows from these component timings. Hardware was one hosted
arm64 runner; other machines and Swift versions may differ.

## Follow-up: normalized exact-check guard

A separate incremental study uses this harness to skip a repeated exact-match
predicate when media qualifier removal leaves the token sequence unchanged.
See [EXACT_CHECK_RESEARCH.md](EXACT_CHECK_RESEARCH.md) for the pinned parent
baseline, opt-in workloads, portable results, and pending native qualification.
