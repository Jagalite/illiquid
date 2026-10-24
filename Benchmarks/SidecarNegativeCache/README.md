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

## Results: portable memory improvement, native qualification pending

The complete Linux campaign finished on 2026-10-24 with **108 observations**:
nine workloads, six alternating AB/BA pairs per workload, and two variants.
It used Swift 6.3.2 on x86_64 Linux with glibc 2.39, release optimization and
whole-module optimization. The measured implementation is
`47c6b816fd57c2eb7083d1daf8c3440dbed9ea68`; later commits add only reporting and
evidence. The baseline reader is byte-identical at its recorded baseline
`6f70cd2446fc6ef38d4e5a0fbf96f91b2234e635` and the PR base
`4abf4b44f13386ccd04f1ce4ad0e756255ca4d14`.

### Retained allocator memory

All seven workloads containing missing or unusable sidecars reduced retained
allocator growth by **51.7% to 62.4%**. The positive-only control was effectively
unchanged; the early-return extras control retained no additional bytes.

| Workload | Media paths | Baseline bytes | Candidate bytes | Paired median change |
| --- | ---: | ---: | ---: | ---: |
| Missing sidecars | 512 | 232,784 | 97,760 | -58.0% |
| Missing sidecars | 8,192 | 3,673,872 | 1,576,816 | -57.1% |
| Missing, cache-limit stress | 50,010 | 26,894,016 | 10,116,592 | -62.4% |
| Mixed metadata | 8,192 | 3,756,672 | 1,813,344 | -51.7% |
| All positive | 8,192 | 4,985,328 | 4,985,448 | +0.0022% |
| Unsupported NFO contents | 8,192 | 3,686,240 | 1,592,912 | -56.8% |
| Distinct parent folders | 4,096 | 6,760,856 | 2,566,704 | -62.0% |
| Unicode paths | 1,024 | 479,696 | 213,968 | -55.4% |
| Skipped extras | 8,192 | 0 | 0 | No change |

Byte columns are independent medians of the first scan's retained allocator
delta; percentages are the median of six paired percentage changes. The cap
case saves **16,777,424 bytes (about 16 MiB)**, from **25.65 MiB to 9.65 MiB**.
The positive-only difference between independent medians is **+120 bytes**.
These values describe the live scan-reader fixture, not total application RAM.

The second scan retains similar memory. Post-release medians range from zero
to 6,016 bytes and are not uniformly lower in the candidate. For example, the
mixed case ends at 1,288 baseline / 3,200 candidate bytes, and unsupported NFO
contents at 2,888 / 6,016 bytes. These aggregate allocator residuals are included
in the raw results and are not selectively subtracted from retained memory.
The original reader already releases its cache at the end of a scan; this
change reduces memory held during the scan rather than fixing a leak.

### Timing: unresolved tradeoffs

There is **no general speedup or timing non-regression conclusion**. The
following values are median paired percentage changes; positive means slower.
Every observation, including adverse results, is retained.

| Workload | First wall | First CPU | Cached wall | Cached CPU |
| --- | ---: | ---: | ---: | ---: |
| Missing 512 | -16.79% | -15.18% | -18.68% | -21.06% |
| Missing 8,192 | +9.30% | -0.72% | +17.53% | +7.48% |
| Missing, cache-limit stress | -22.74% | -21.83% | -28.05% | -22.18% |
| Mixed 8,192 | +2.22% | -9.50% | -45.69% | -28.19% |
| All positive 8,192 | -7.61% | +4.65% | +14.95% | +23.14% |
| Unsupported NFO 8,192 | -30.73% | -21.45% | -31.62% | -3.41% |
| Distinct parents 4,096 | +54.51% | +58.39% | +25.11% | +4.70% |
| Unicode 1,024 | -6.39% | -13.75% | +7.65% | -2.85% |
| Skipped extras 8,192 | +29.94% | +14.73% | +10.78% | -2.21% |

The distinct-parent first scan has five of six slower CPU pairs, with paired
CPU changes ranging from -5.06% to +96.76%. Positive-only cached scans also
have five of six slower CPU pairs, ranging from -7.59% to +232.90%. These are
material adverse observations requiring native follow-up, even though the
unchanged extras control also has large timing variation. Noise does not
establish the absence of a regression.

For scale, the independent wall-time medians for the distinct-parent first
scan are 1,720.69 ms baseline / 2,977.51 ms candidate; for positive-only cached
scans they are 2,120.37 / 2,641.01 ms. Ratios of these independent medians differ
from the paired percentages in the table. The full ranges and individual pairs
are in [summary.json](evidence/linux/summary.json) and
[measurements.jsonl](evidence/linux/measurements.jsonl).

### Correctness and readiness

Both reader implementations pass all **63 portable component tests** in debug
and release (four successful test configurations). Complete recognition output and
`filesRead` match for **194,625 output snapshots**: 193,204 across both passes
of the nine memory workloads, plus 1,421 across 15 existing scenarios. The
macOS-only `PlexMatchReaderRegressionTests` suite is excluded by its existing
platform guard on Linux; these results do not qualify the full macOS app.

An independent read-only audit verified all source snapshots, compiler
adaptations, staged binary hashes, test logs, complete-output receipts,
measurement order, process-output hashes, delta arithmetic, summary statistics
and completion hashes. No timed observations were discarded or rerun.

Native component measurements and full app/discovery integration were
submitted for implementation commit
`47c6b816fd57c2eb7083d1daf8c3440dbed9ea68` in
[workflow run 40101146816](https://github.com/Jagalite/illiquid/actions/runs/40101146816).
Both jobs remain **queued**, with no native result available at report time.
The research PR stays a draft pending native correctness, allocator results
and review of the timing tradeoffs. The portable memory result supports the
proposed representation change; it does not establish merge readiness.

### Evidence index

- [Exact source/compiler manifest](evidence/linux/manifest.json) and
  [environment](evidence/linux/environment.json).
- [Four test receipts](evidence/linux/tests.json), with the full test/build logs
  and original source snapshots in [evidence/linux](evidence/linux).
- [Complete-output verification](evidence/linux/verification.json) and ten
  compressed canonical output files in the same directory.
- [Raw observations](evidence/linux/measurements.jsonl),
  [summary](evidence/linux/summary.json), and
  [command receipts](evidence/linux/commands.jsonl).
- [Completion inventory and SHA-256 hashes](evidence/linux/completion.json).
- [Independent audit receipt](evidence/linux/independent-audit.json).

The completion inventory covers the runner's original evidence. The independent
audit and earlier checkpoint receipts were added afterward. All measured
source, test, and harness bytes remain identical to the implementation commit.

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
