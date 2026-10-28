# Media display-name formatting

This experiment compares complete production sources against frozen main commit
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`. Only `MediaNameRecognition.swift`
differs. The shared `MediaMetadataHints.swift` must match its pinned bytes.
The baseline manifest records the commit, Git blob IDs, and SHA-256 hashes.

```sh
python3 Benchmarks/MediaDisplayName/run.py \
  --pairs 10 --target-ms 100 --output /tmp/media-display-name-results
```

Follow `AGENTS.md` and use Kyoto when available. The runner itself does not submit
queue jobs. Use a new or empty output directory; it refuses to overwrite evidence.
It requires Python 3 and Swift 6.1 or newer, with native Foundation on macOS.
There are no media dependencies or dependency downloads.

## Measured work

The `cached-*` cases receive already recognized metadata, as the media scanner
normally provides to the browser, and time the public `displayName` getter.
The `recognize-*` cases include `recognize(relativePath:).displayName` in the
timed operation. These are distinct boundaries, not whole-application timings.

| Case | Workload |
| --- | --- |
| `cached-numbered` | Ordinary seasons and episode numbers |
| `cached-ranges` | Numbered episodes with an optional final episode |
| `cached-wide-numbers` | Three-digit seasons and four-digit episodes |
| `cached-unicode-titles` | Numbered episodes with Unicode episode titles |
| `cached-dated-control` | Air dates bypass numeric formatting |
| `cached-movie-control` | Movie names and years |
| `cached-unknown-control` | Unclassified names |
| `cached-unbounded-control` | Negative and large metadata-hint integers |
| `recognize-numbered` | Complete filename recognition and numbered label |
| `recognize-ranges` | Complete filename recognition and range label |
| `recognize-mixed` | Complete recognition and labels for mixed media |

The unbounded case is a compatibility/fallback workload, not an unchanged code
path: range-prefix construction differs. Dated, movie, and unknown cases are
the unchanged-path controls. Preserve their observations even if they fluctuate.

Fixture creation, preflight, warmup, JSON encoding, and verification are outside
the timers. The loop includes label construction, a small byte-count observation,
and bounded result-array handling. It retains the final complete batch across the
timer boundary and verifies every label's exact UTF-8 bytes afterwards. No empty
loop is subtracted. Wall time uses `DispatchTime`; process CPU uses
`CLOCK_PROCESS_CPUTIME_ID`.

## Correctness and sampling

The runner tests baseline and candidate in debug and release with the existing
recognition suites and `MediaDisplayNameTests`. These currently comprise 28 tests;
the actual nonzero completed count is required and recorded for each invocation.
The new regression oracle retains the original Foundation formatting expression,
including all 10,000 bounded values, signed C conversion boundaries, nil values,
air-date precedence, exact Unicode, non-episode kinds, and public hint application.

Both variants emit complete differential records before timing. The runner
compares all input and stored/derived fields, and retains both compressed outputs.
The timed driver also checks its complete final labels and per-batch checksum.

Each production variant is a separately optimized shared `IlliquidCore` module.
The common driver is compiled separately without cross-module optimization, so
the compiler cannot specialize or hoist production calls using fixture contents.

Calibration uses balanced fresh-process pilots and equal iteration counts until
the faster variant reaches the target. Final observations use fresh processes,
rotate case order, and balance AB/BA order with an even pair count. Pilots are
retained separately and excluded from final summaries. No samples are omitted.
Summaries report absolute per-operation timings, all paired reductions, ranges,
and process CPU, including adverse observations.

## Options and evidence

`--tests-only` stops after four test runs. `--correctness-only` additionally builds
both optimized variants and compares outputs without timing. `--skip-tests` is
for exploratory screening and records that tests were skipped. `--swift` and
`--swiftc` select explicit tools; their environment-variable forms also work.
`--summarize-only` recomputes a summary from existing retained observations.

| Output | Contents |
| --- | --- |
| `manifest.json`, `source-receipts.json`, `inputs/` | Exact inputs and baseline, compiler/SDK/environment provenance |
| `tests.json`, `tests/`, `packages/` | Test sources, commands, counts, logs, and hashes |
| `build-receipts.json` | Module/driver commands and binary hashes |
| `differential.json`, `differential-*.json.gz` | Full-output parity and complete records |
| `cases.json`, `iterations.json`, `calibration.jsonl` | Workloads and every calibration observation |
| `measurements.jsonl`, `processes/` | Every final observation and hashed process log |
| `summary.json`, `commands.jsonl` | Summaries and execution receipts |

Retain inputs, manifests, logs, and raw samples; compiled products and caches need
not be committed. The runner rechecks staged source and executable/library hashes
before reporting successful measurements.

[The row-projection experiment](../MediaDisplayNameProjection/README.md) measures
the surrounding production row construction and a cached-projection control.
[The historical recognition verifier](../MediaNameRecognition/README.md) retains
its own frozen result type so derived-property regressions cannot be hidden.
The final results and limitations belong in
[`MEDIA_DISPLAY_NAME_PERFORMANCE.md`](../../Documentation/MEDIA_DISPLAY_NAME_PERFORMANCE.md).
