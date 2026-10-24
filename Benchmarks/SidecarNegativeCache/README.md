# Sidecar negative-cache memory research

`MediaSidecarReader` lives for one background metadata scan. Its original
`[String: Sidecar]` stores both parsed hints and missing-file results. Every
dictionary value reserves room for the enum's largest metadata payload, even
when the value is `.missing`. Large libraries without per-file sidecars retain
that unused space until their reader is released.

The candidate keeps missing/unusable paths in a `Set<String>` and successful
parses in the existing dictionary. Both stores share the original 50,000-entry
cap. Lookup still precedes the admission guards, so cached metadata remains
available after the entry cap or 16 MiB read budget is exhausted. File-opening
flags, per-file limits, negative-cache lifetime, parse/read accounting,
precedence, cancellation checkpoints and String key equality are unchanged.

## Qualification status

Both reader implementations pass all 63 portable component tests in debug and
release. The [portable correctness receipts](evidence/linux/tests.json),
[exact-source manifest](evidence/linux/manifest.json), and compressed test logs
are retained in `evidence/linux/`. The complete measurement campaign is still
running; no timing conclusion is made from correctness-test durations.

Native macOS qualification is running for implementation commit
`47c6b816fd57c2eb7083d1daf8c3440dbed9ea68`:
[workflow run 40101146816](https://github.com/Jagalite/illiquid/actions/runs/40101146816).
Results and validation receipts will be added here when that run completes.

## Reproduce

From a checkout containing baseline reader commit
`6f70cd2446fc6ef38d4e5a0fbf96f91b2234e635`, with Swift 6.1+ and Python 3.10+:

Follow the build coordination in `AGENTS.md`: submit the command below through
the configured Kyoto queue when that queue is available. The isolated Linux
workspace and ephemeral GitHub runners do not have the user-volume queue; their
component builds run serially in separate baseline/candidate build directories.

```sh
python3 Benchmarks/SidecarNegativeCache/run.py \
  --output /tmp/illiquid-sidecar-negative-cache --pairs 6
```

The destination must not exist. `--tests-only` runs both implementations'
debug/release suites and the complete-output comparisons without memory/timing
observations. `--cases` and `--skip-tests` support explicitly labelled
exploration; they are not used by native qualification.

The runner snapshots the five current metadata sources, all seven test files,
the drivers and allocator helper. Only the historical `MediaSidecarReader.swift`
is substituted in the baseline: both variants use identical current recognizer
and parser dependencies. This isolates the reader change rather than comparing
complete historical application revisions. Native source bytes are unchanged.
Linux substitutes the reader's Darwin import with Glibc and adds FoundationXML
to the NFO parser; original and compiled hashes record those adaptations.

## Method

Nine deterministic workloads exercise 512 and 8,192 missing sidecars; a
50,010-path cap stress; mixed and positive-only metadata; readable but
unsupported metadata; distinct parent folders; Unicode paths; and the
extra-file early return. The scenario key `malformed-8192` uses well-formed XML
with an unsupported root; it exercises a read followed by a failed metadata
parse, not structural XML corruption. Fixture directories and sidecar files
are created before measurement. Media URL arrays are also constructed before
measurement; the reader never opens media payloads, so those files need not
exist.

Each fresh process warms a separate reader with at most 64 inputs, then samples
allocator live bytes before and after a complete scan. The same measured
reader performs a second scan to expose cached-lookup costs. On macOS each scan
drains its autorelease pool before sampling. `withExtendedLifetime` keeps the
reader alive through the retained samples, and a non-inlined helper returns
only scalar receipts before a final post-release sample. No recognized output
arrays are retained in the measured interval. Post-release deltas are reported
without subtracting them selectively from the retained result.

The metric comes from the existing `RuntimeLeaseHistory/CLeaseHeap` helper:

- macOS: `malloc_zone_statistics(NULL).size_in_use`.
- Linux: `mallinfo2().uordblks + mallinfo2().hblkhd`.

These are additional allocator-accounted live bytes while one scan-local
reader is alive, including the reader/path plan and any remaining framework
allocation changes. They are not an exact object-size measurement, process
RSS, peak footprint, whole-player memory, or an accumulating leak. Exact totals
also depend on fixture path lengths.

Six alternating AB/BA pairs use independent processes and identical inputs.
Every raw observation is retained. Reports include independent medians and
ranges, plus all paired differences and paired percentage changes. A median
paired percentage need not equal the percentage calculated from independent
medians. Ratios are omitted for nonpositive baseline values; tiny/empty control
results should be interpreted in bytes rather than percentages.

Timing includes actual sidecar probes/parsing, recognition, a small identical
result consumer and autorelease draining. Input/fixture creation, complete-output
comparison and JSON serialization are outside timing. Filesystem caches are
warm; this is not a cold-disk or frame-rate benchmark.

## Correctness gates

The runner compares all stored and derived recognition fields and `filesRead`
for two passes over every memory workload. It additionally runs the existing
15 path-plan/precedence scenarios (1,421 outputs). Every timed receipt must
match the independently verified count/checksum. Expected read counts and
recognized kinds prevent fixtures from silently exercising an early-return
path. Unsupported allocator metrics and invalid timing receipts fail the run.

Both reader versions run the same behavioral tests, including newly created
sidecars after cached misses, replacement of malformed/rejected sidecars,
canonical Unicode String equality, the exact mixed-entry cap, and rejected
contents consuming the byte budget. Existing coverage includes cancellation,
symlink rejection, source boundaries, inherited metadata, parser limits and
the 64-folder path-plan bound.

The dedicated workflow uses an Apple Silicon macOS runner for component
measurements and a separate pinned-SDK application build with related discovery
tests. Full measurements run on the research branch or manual dispatch;
matching pull requests run correctness gates. This keeps performance claims
tied to the recorded cohort rather than treating noisy timing as a CI gate.
