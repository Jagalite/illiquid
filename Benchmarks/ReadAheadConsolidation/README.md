# Read-ahead consolidation provenance

The production gate and original 14-test suite remain exactly those of PR #231,
head `eef40bf2489d60cdd97354e3b611fc64d6d98da0`. PR #192's 15-test suite is
preserved as `MediaReadAheadGatePerformanceTests`; PR #160's 12-test suite is
preserved as `MediaReadAheadGateEOFTests`. Only their enclosing type names change.
Every test name, assertion, parameterization, timeout, and iteration remains.

All three isolated runners stage these three suites (41 declared tests; the two
parameterized EOF tests yield 43 individual cases). Debug and release on baseline
and candidate provide 164 declared-test executions per runner. Native integration
selects all three suites plus two existing integration tests (43 declared tests).
Use `--no-parallel` as configured to serialize suites; each test uses its own gate.

All benchmark workloads, baseline hashes/blobs, baseline source, drivers, probes,
counting wrappers, pairing, controls, and performance guards are unchanged.
Existing historical evidence and its original README/RESULTS interpretation are
retained verbatim, including adverse controls and incomplete attempts. They describe
their recorded commits, not this consolidation. The provenance JSON hashes every
original PR file; no new runtime or performance qualification is claimed here.

PR #160's implementation suppressed EOF-only notifications but retained broadcasts
for timestamped readers. PR #192 also used a minimum timestamp hint. PR #231 keeps
the exact negation of the original blocking predicate, counts physical waiters,
notifies observers only on first-reader transition, and clears stale hints. No
older production implementation is imported. Workload comparisons must be rerun
against the consolidated source before making new performance claims.

## Validation after integration

Run from the actual integrated checkout, one command at a time via Kyoto; choose
fresh absolute output paths. Inspect each job's `show`, `logs`, and `wait` receipts.

```sh
python3 /Volumes/seed1/Projects/kyoto/kyoto.py submit -- python3 Benchmarks/SubtitleReadAheadWakeups/run.py --queued --pairs 7 --output /ABS/FRESH/subtitle-read-ahead
python3 /Volumes/seed1/Projects/kyoto/kyoto.py submit -- python3 Benchmarks/MediaReadAheadGate/run.py all --pairs 6 --updates 240 --interval-us 8333 --output /ABS/FRESH/media-read-ahead/120hz
python3 /Volumes/seed1/Projects/kyoto/kyoto.py submit -- python3 Benchmarks/MediaReadAheadGate/run.py benchmark --pairs 6 --updates 120 --interval-us 16667 --output /ABS/FRESH/media-read-ahead/60hz
python3 /Volumes/seed1/Projects/kyoto/kyoto.py submit -- python3 Benchmarks/MediaReadAheadGate/run.py benchmark --pairs 6 --updates 60 --interval-us 33333 --output /ABS/FRESH/media-read-ahead/30hz
python3 /Volumes/seed1/Projects/kyoto/kyoto.py submit -- python3 Benchmarks/ReadAheadEOF/run.py --pairs 6 --duration 3 --output /ABS/FRESH/read-ahead-eof
python3 /Volumes/seed1/Projects/kyoto/kyoto.py submit -- swift test --force-resolved-versions -c release --jobs 2 --no-parallel --filter 'MediaReadAheadGate(Performance|EOF)?Tests|subtitleReaderWaitsForProgressAndSeekInvalidatesOldRead|closingReadAheadWakesBlockedInput'
```

The subtitle runner retains seven workloads and seven pairs: 98 timed observations
plus its mechanism probes. The minimum-hint runner retains five counted scenarios
and four timed scenarios: 10 counted plus 48 timed observations per cadence, 174
observations across three cadences. The EOF runner retains five scenario/rate
combinations and six pairs: 60 observations, three seconds each.

These are gate/component measurements. Neither historical receipts nor future
successful isolated tests establish live app UI, playback, or energy qualification.
