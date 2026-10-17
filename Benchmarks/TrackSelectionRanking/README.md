# Track selection ranking benchmark

This component benchmark compares the actual `TrackSelectionPreferences.select`
implementation with the frozen source at
`68274d1b09dcc866296321a5a8858efc297c4f19`. Both variants compile the complete
production `MediaTrack.swift` and their complete selection-preferences source.
There are no platform stubs or copied ranking algorithms.

## Reproduce

Use matching Swift 6.1-or-newer `swift` and `swiftc` tools. The native workflow
uses Xcode 26.6 and macOS 26, matching the application's deployment target.

```sh
python3 Benchmarks/TrackSelectionRanking/run.py test --configuration debug --output /tmp/track-ranking-debug
python3 Benchmarks/TrackSelectionRanking/run.py test --configuration release --output /tmp/track-ranking-release
python3 Benchmarks/TrackSelectionRanking/run.py benchmark --output /tmp/track-ranking-benchmark
```

Tests default to both baseline and candidate; `--variant baseline` or
`--variant candidate` selects one. The isolated package runs
`Tests/IlliquidCoreTests/TrackSelectionRankingTests.swift` using the toolchain's
bundled Swift Testing. It has no external package dependencies. The existing
restoration-regressions workflow also runs the complete native release suite,
including the pre-existing track-selection and player integration tests.

`--swiftc` / `SWIFTC` and `--swift` / `SWIFT` select another installed toolchain.
The runner prefers `swift` beside the selected compiler. On Linux, configure
the toolchain's normal runtime library search path when needed. All generated
sources, packages, build products, temporary files, and caches reside under the
required `--output` directory; `HOME` is unchanged.
Use a fresh output directory for each run so existing evidence is preserved.

The benchmark defaults to ten paired rounds, with five AB and five BA pairs
for every workload. Each timed row runs in a fresh process. Before the final
cohort, separate pilot processes calibrate an iteration count for each workload
so the faster variant's pilot interval reaches at least 20 ms. Both variants
then use that exact count in every final pair. `--target-ms` changes the target;
`--iterations` supplies a fixed count and skips calibration.

A quick compilation/parity/timing smoke check is:

```sh
python3 Benchmarks/TrackSelectionRanking/run.py benchmark --rounds 2 --iterations 1000 --output /tmp/track-ranking-smoke
```

Smoke timings are unsuitable for a performance claim. Regenerate summaries
from the retained final measurements with:

```sh
python3 Benchmarks/TrackSelectionRanking/run.py summarize --output /tmp/track-ranking-benchmark
```

## Workloads and timing boundary

| Workload | What it exercises |
| --- | --- |
| `audio-0-none`, `audio-0-languages` | No eligible audio tracks, with empty or three-language preferences |
| `audio-1-none`, `audio-1-languages` | A lone eligible audio track; both versions already avoid ranking it |
| `audio-2-none`, `audio-2-languages` | Two audio tracks, without or with ordered language preferences |
| `audio-8-none`, `audio-8-languages` | Eight audio tracks with language and track-flag variation |
| `audio-32-none`, `audio-32-languages` | Larger 32-track audio catalog |
| `subtitle-automatic` | Preserve a valid demuxer fallback, or return nil when none exists |
| `subtitle-off` | Disabled subtitles with a stored language preference |
| `subtitle-always` | Rank eight subtitle tracks without a language preference |
| `subtitle-forced-languages` | Forced-only with explicit English/Japanese preferences, dedicated forced tracks, and bitmap filtering flags |
| `subtitle-forced-audio-fallback` | Forced-only derives the language policy from English or Japanese audio |
| `mutable-preferences` | Reassign raw public preference fields before each audio/subtitle selection, including aliases, duplicates, and invalid language entries |

Ordinary workloads make two selections per iteration: original/reversed
catalog order, different fallbacks, and (for audio) a variant containing
unrelated subtitle tracks. The mutable workload makes four selections per
iteration and intentionally includes the five preference-field assignments.
Candidate construction, initial preference construction, and warm-up are
outside timing. `select`'s own sanitization, filtering, normalization, ranking,
and temporary allocation costs remain inside it.

Each production variant is built as an optimized shared `IlliquidCore` module.
The same independently optimized driver links to each one, without cross-module
optimization or an inlinable copy of `select`. Thus the driver cannot see the
production function body and hoist repeated selections. Every selected ID
contributes to a retained checksum and non-nil count; warm-up outputs are also
retained. Pair validation requires all output/count fields to agree.

## Correctness and provenance

Before timing, both binaries emit complete selected-ID arrays for 55,296
deterministic selections: 64 raw preference states, 27 catalog/order variants,
both track kinds, four fallback positions, and four audio-language contexts.
Catalogs include empty and singleton cases, all combinations of five track
flags, mixed kinds, equivalent and invalid language identifiers, and extreme
signed 64-bit IDs. Preference states cover every subtitle policy, both
accessibility/commentary settings, aliases and duplicates, and the 32-entry
sanitization boundary. The runner compares the entire receipts, including
catalogs and selected IDs; checksum equality alone is not the correctness gate.
The new unit tests supply independently stated semantic expectations.

The baseline manifest pins the Git commit, Git blob IDs, and SHA-256 hashes.
The shared `MediaTrack.swift` must still match that manifest. Every invocation
stages the actual source, harness, and runner bytes before compiling and records
their hashes, toolchain path/version/binary hashes, exact commands, build-product
hashes, and test logs. Calibration observations, final raw JSONL measurements,
process logs, full differential receipts, iteration counts, and summary JSON
are retained separately. No build products need to be committed.

Results describe component selection cost on the recorded platform. Linux uses
real Foundation but does not establish macOS timing. This benchmark does not
measure overall media-open latency, decoder throughput, frame pacing, or
visible playback. The zero/one-track and subtitle automatic/off controls
expose unchanged paths alongside ranking improvements. Native CI publishes
its independent measurements as `track-selection-ranking-native`; timings
are evidence, not a noisy percentage-based CI pass/fail threshold.
