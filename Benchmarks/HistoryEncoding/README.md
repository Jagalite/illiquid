# Playback history JSON encoding

## Result

The retained change makes playback-history JSON smaller by omitting optional
forward-slash escapes. With 10,000 synthetic records, payload reduction is **7.17%
for normal folder paths**, **8.25% for deep paths**, **5.91% for Unicode/escaping-heavy
paths**, and **2.78% for short paths**. The empty-history control is unchanged.
All 208 process outputs have equal decoded values and exactly the predicted byte
reduction. This is a measured serialization-size improvement, with supporting
Linux write-latency observations; macOS latency remains unqualified.

The production change is confined to the history writer's local `JSONEncoder`:
`outputFormatting = [.withoutEscapingSlashes]`. Foundation's
[documented option](https://developer.apple.com/documentation/foundation/jsonencoder/outputformatting-swift.struct/withoutescapingslashes)
omits the optional backslash before `/`. History is standalone JSON `Data` in
`UserDefaults`, so it does not need the escaping used for embedding JSON in HTML.
A path such as `"\/Volumes\/Media\/movie.mkv"` becomes
`"/Volumes/Media/movie.mkv"`; the decoded string is identical.

There is no schema migration, decoder change, new cache, history truncation,
writer scheduling change, or preference-encoder change. Whole-history traversal
and the existing snapshot/copy-on-write behavior remain.

## Measured payloads

These are exact JSON `Data` byte counts handed to `UserDefaults.set`, not RSS or
physical disk write counts. All measurements use Swift 6.3.2 on Linux x86_64.

| Paths | Entries | Baseline bytes | Candidate bytes | Bytes saved | Reduction |
|---|---:|---:|---:|---:|---:|
| empty | 0 | 560 | 560 | 0 | 0.00% |
| short | 1 | 1,747 | 1,733 | 14 | 0.80% |
| normal | 1 | 2,328 | 2,255 | 73 | 3.14% |
| deep | 1 | 3,168 | 3,015 | 153 | 4.83% |
| escaped | 1 | 2,572 | 2,499 | 73 | 2.84% |
| short | 1,000 | 86,440 | 83,994 | 2,446 | 2.83% |
| normal | 1,000 | 226,513 | 209,999 | 16,514 | 7.29% |
| deep | 1,000 | 422,905 | 387,687 | 35,218 | 8.33% |
| escaped | 1,000 | 275,473 | 258,959 | 16,514 | 5.99% |
| short | 10,000 | 877,275 | 852,895 | 24,380 | 2.78% |
| normal | 10,000 | 2,298,713 | 2,133,902 | 164,811 | 7.17% |
| deep | 10,000 | 4,258,937 | 3,907,438 | 351,499 | 8.25% |
| escaped | 10,000 | 2,787,109 | 2,622,298 | 164,811 | 5.91% |

## Write-latency observations

The timed interval is a changed public-API playback mutation followed by the
production writer's synchronous flush, including snapshot capture, encoding,
queue coordination, and real `UserDefaults.set`. The empty control uses an
unconditional bulk clear. It does not time fsync or isolate encoder CPU.

Each table median is the median of eight process medians, with eleven measured
writes per process after three warm-up writes. The paired percentage is computed
from each baseline/candidate pair's medians, so it need not equal the percentage
between the two aggregate medians. Negative paired change means a shorter
candidate interval.

| Paths | Entries | Baseline median (ms) | Candidate median (ms) | Median paired change |
|---|---:|---:|---:|---:|
| empty | 0 | 0.076 | 0.072 | -6.45% |
| short | 1 | 0.202 | 0.202 | +1.40% |
| normal | 1 | 0.244 | 0.243 | -5.50% |
| deep | 1 | 0.305 | 0.302 | -2.04% |
| escaped | 1 | 0.276 | 0.250 | -7.77% |
| short | 1,000 | 7.531 | 7.369 | -1.31% |
| normal | 1,000 | 15.691 | 14.563 | -5.48% |
| deep | 1,000 | 25.971 | 23.580 | -8.32% |
| escaped | 1,000 | 20.516 | 19.274 | -5.96% |
| short | 10,000 | 79.889 | 78.352 | -2.17% |
| normal | 10,000 | 161.143 | 150.324 | -5.35% |
| deep | 10,000 | 269.012 | 244.274 | -10.45% |
| escaped | 10,000 | 202.172 | 188.547 | -6.29% |

Timing is secondary evidence. Individual pairs vary, and the short one-record
control has a +1.40% paired change despite nearly identical aggregate medians.
The empty control also moves although it has no slash bytes to save. Preserve
these controls and all samples instead of attributing every timing change to the
optimization. The 10,000-record normal, deep, and escaping-heavy cases show median
paired changes of -5.35%, -10.45%, and -6.29%, respectively, on this host.

This was a shared Linux runner. Compiler/build/output and `XDG_CONFIG_HOME` used
`/dev/shm` because regular host storage was unstable. These timings must not be
presented as macOS application performance or physical-disk results. Native
Foundation qualification is provided by the macOS workflow; its
[pre-PR run](https://github.com/Jagalite/illiquid/actions/runs/40640065106) was still
queued when this evidence was collected. No playback FPS, renderer, RSS, startup,
or energy improvement is claimed.

## Protocol and correctness

The baseline is `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`. The runner snapshots the
actual production persistence store, writer, URL/track types, and instrumentation.
It checks every shared dependency is byte-identical between variants. Two simple
supporting enum declarations are extracted intact from their production files;
full-file and extracted-source hashes are retained. No copied StoredState schema
or alternate encoder models the timed path.

Each variant is compiled with `-O -whole-module-optimization -swift-version 6
-warnings-as-errors` into its own `IlliquidCore` dynamic library. A separate
executable imports that module. Fixtures are constructed through production
public APIs; setup, payload export, and restore verification are outside timing.
They include positions/durations, completion, last-watched paths, restore targets,
track/subtitle settings, content versions, and ordered replacement histories.

There are 13 workloads: empty plus 1, 1,000, and 10,000 records with short, normal,
deep, and Unicode/required-escaping-heavy paths. Eight fresh-process pairs per
workload alternate AB/BA, with four of each order: **208 processes and 2,288 timed
history writes**. Every process reloads and verifies records through the real
store. Complete decoded JSON and type-sensitive canonical bytes are compared
across all results; only the Set-derived `completedFiles` array is sorted. Each
pair must save exactly one byte per forward slash in all decoded string keys and
values. Quotes, backslashes, control characters, Unicode, and ordered arrays are
preserved.

Regression qualification ran the same seven existing persistence test files on
baseline and candidate in both debug and release, with warnings treated as
errors. The baseline reported **26 XCTest + 27 Swift Testing tests (53)** per
configuration. The candidate reported **29 XCTest + 27 Swift Testing tests (56)**,
including three new tests for encoding/required escapes, legacy escaped history,
and empty/history-disabled state with a separate preferences encoder. Existing
suites cover coalescing, error/retry, unreadable-history protection, concurrent
writes, lifetime ordering, and 10,000/100,000-entry history preservation.

All four regression commands passed. A benchmark-only `UserDefaults` Sendable
declaration was removed after those tests to accommodate Linux Foundation; the
final timed run then completed. The retained receipts verify production source
hashes are identical between regression and measurement stages.

## Reproduce

Use a checkout containing the pinned baseline commit and Swift 6.1 or newer.
No native FFmpeg/GUI dependency graph is built by this focused runner. CI uses
macOS 26 / Xcode 26.6 and fetches complete git history.

```sh
python3 Benchmarks/HistoryEncoding/run.py --output /tmp/illiquid-history-encoding
# Smaller exploratory workload (not the retained formal cohort):
python3 Benchmarks/HistoryEncoding/run.py --mode benchmark --quick \
  --pairs 2 --iterations 5 --output /tmp/illiquid-history-encoding-quick
```

Outputs must be new or empty. `--mode tests` runs just the regression suites.
When the shared Kyoto queue exists, submit the complete runner through it and
pass `--queued`; the runner refuses an unqueued build when Kyoto is available.
Builds sharing a build directory remain serialized.

```sh
python3 /Volumes/seed1/Projects/kyoto/kyoto.py submit -- \
  python3 Benchmarks/HistoryEncoding/run.py --queued \
  --output /tmp/illiquid-history-encoding
```

## Retained evidence

[evidence/linux-x86_64](evidence/linux-x86_64) contains complete summary and raw
observations, successful regression command receipts and full regression logs,
source/binary hashes, execution-context limitations, and the production patch.
Every process output was fully compared and retains its raw and canonical
SHA-256 hashes. `audit.json` records the independent recheck of all 26 complete
archived payloads, exact byte reductions, test logs, source hashes, and statistics.

`validation.json` joins the successful test and measurement stages.
`SHA256SUMS` covers the checked-in evidence files. The original binary archives
were omitted after their upload was interrupted; their hashes are retained in
`audit.json`. The runner reproduces full command logs, exact source snapshots,
and complete per-workload payloads. The dedicated GitHub workflow uploads those
as artifacts when it runs. No benchmark values were inferred from a CI run that
has not completed.
