# Playback-history JSON encoding

## Question and candidate

Does omitting JSON's optional slash escapes reduce the cost of writing Illiquid's
path-heavy playback history? The frozen baseline is
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`.

The candidate configures only the history snapshot's JSONEncoder with
`.withoutEscapingSlashes`. File paths appear repeatedly as dictionary keys and
values. The serialized document keeps its existing schema and decodes to the
same values. Preferences use their existing separate encoder; session documents,
write coalescing, history policy, failure handling, and destination are unchanged.
This is not a replacement for the remaining whole-history serialization work.

## Reproduce

Use macOS 26 with the project's Swift toolchain and Python 3. The runner stages
the complete unmodified IlliquidCore source target from the pinned baseline and
the candidate working tree. Only PlaybackPersistenceStore.swift may differ.
It requires no FFmpeg SDK, third-party package download, media, or app launch.

Follow AGENTS.md: submit through Kyoto when that shared queue is available.
Hosted CI has no Kyoto installation and executes builds, measurements, and tests
serially. The output directory must be new or empty.

~~~sh
git fetch --no-tags --depth=1 origin ea2ff568237e2667f7b1aeee67b11a44ebe95b72
python3 Benchmarks/HistoryJSONEncoding/run.py \
  --pairs 8 --output /tmp/illiquid-history-json
~~~

`--verify-only` runs all preflight cases and both test configurations without
collecting a timing cohort. An explicit compiler can be selected with
`--swift /path/to/swift`. Both variants use optimized SwiftPM release builds.

## Workloads

All paths and metadata are synthetic. Each observation starts a fresh process,
seeds an isolated UUID UserDefaults suite, loads the actual production store,
checks the seed, performs four untimed warmups, and lets their delayed drains
finish. The measured loop alternates a single position between 120.25 and 121.25
seconds and synchronously flushes after every change. The empty control instead
clears an already empty history; that existing operation deliberately writes.
Every observation requires exactly one completed history callback per operation.

| Workload | Records | Writes per observation | Contents |
| --- | ---: | ---: | --- |
| empty | 0 | 200 | Empty history and standard preferences; no path escaping |
| small-100 | 100 | 100 | Positions/durations, ordinary six-separator paths |
| progress-1000 | 1,000 | 40 | Same progress schema |
| rich-1000 | 1,000 | 20 | Versions for all records, settings for one in four, completed status for one in five, folder mapping per 24, two archives per 20 |
| deep-1000 | 1,000 | 40 | Progress schema with additional directory components; path-depth stress |
| unicode-1000 | 1,000 | 20 | Rich schema with Japanese text, emoji, quotes, literal percent text, and backslashes in metadata |
| rich-10000 | 10,000 | 4 | Rich-history size stress |

These are controlled workload dimensions, not a claim about typical user
libraries or checkpoint frequency. The normal path is
`/Volumes/Media/TV/Series-N/Season 01/Episode N.mkv`.

Two destinations are reported independently:

- **defaults:** the actual UserDefaults.set callback, with a small subclass
  counting completed writes and Data bytes.
- **memory:** the same production store and writer with only the destination
  replaced by an in-memory Data sink. This isolates encode-plus-queue service
  time from the preferences service; it is not an encoder-only microbenchmark.

The timed boundary includes the mutation, snapshot capture, encoding, dispatch,
locking, destination callback, and both writer flushes. Seed generation, load,
warmups, final validation, receipt writing, and cleanup are excluded. A flush
waits for the callback, not fsync. UserDefaults can delegate work to cfprefsd;
its CPU and eventual physical I/O are outside process CPU measurements.

Every submit also schedules the existing 100 ms drain. Immediate flushes leave
those future no-op drains queued. Their unchanged work is included when they
occur during the batch. This measures synchronous mutation-plus-flush component service time,
not the playback controller's asynchronous flush path or steady-state coalescing.

## Correctness and measurement gates

The default experiment has 28 preflight observations and 224 timed observations:
eight pairs for each of seven workloads and two destinations. Each pair has
separate baseline/candidate processes; AB and BA orders are balanced, workload
order rotates, and destination order alternates. Every sample is retained.
Report medians and ranges of per-process batch averages, alongside median
paired reductions and faster-pair counts. These are not per-checkpoint latency
percentiles; CI enforces no time threshold.

Each native observation compares the complete final decoded JSON with an
independently constructed expected fixture, and reloads it through the store.
The Python driver also compares complete normalized outputs between variants
and observations. Object-key order is ignored; only completedFiles (a Set) is
sorted. Ordered version archives remain ordered. The driver verifies that
baseline bytes minus candidate bytes equals one byte per slash, and that all
timed payload identities match preflight.

Debug and release tests run against complete candidate IlliquidCore after the
timing cohort. They include the existing persistence, deferred writer,
idempotence, scaling, history policy, media version, and writer lifetime suites,
plus legacy/raw JSON and difficult-path round trips and an output-format check.
The baseline also runs the legacy/raw and complete-history compatibility tests
in release; the candidate-only output-format assertion is excluded there.
No platform imports or production declarations are replaced with stubs.

The output preserves environment/compiler details, commands, source and binary
SHA-256 identities, raw measurements, schedules, representative payloads, full
test logs, and computed summaries. Source and measured executable identities
are checked again before success. Benchmark binaries are copied before tests,
so later SwiftPM test builds cannot silently replace measured executables.

## Interpretation

Payload size means logical serialized Data bytes passed to the destination.
It is not physical plist size, allocated capacity, peak memory, or durable bytes
written. Timing describes this component on the recorded hosted Mac. It does
not establish playback FPS, decode throughput, energy savings, or the effect
on a particular user's library. The raw measurements and native test outcome
determine whether the candidate is retained; no result is asserted in advance.
