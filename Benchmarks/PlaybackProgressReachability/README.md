# Playback progress predecessor indexing

This experiment measures the complete production progress analyzer used to
qualify the player's deterministic playback state space. The follow-up is
stacked on [PR #174](https://github.com/Jagalite/illiquid/pull/174), with exact
baseline `4077f8ad538dd8ed911b38c9b300a98c787c5135`.

## Change under investigation

Both variants already use the same fair-predecessor worklist and skip the
reachability phase when there are no transaction states or no settled seeds.
The candidate changes only the predecessor table from `[Int: [Int]]` to
`[[Int]]`, indexed by the state's existing dense integer ID. Fair-edge
filtering, predecessor order, worklist seeding, visited-set updates,
classifications, and SCC analysis are unchanged.

The explorer creates a new state at index `nodes.count` immediately before
appending it. Its edge endpoints therefore index `result.nodes`, an invariant
already required by the analyzer's SCC and rank accesses.

Both versions have expected O(V + E) reachability work. The array removes
dictionary hashing for predecessor insertion and lookup, but initializes a
row for every vertex. Index storage is O(V + F), where F is the fair-edge
count; the dictionary has O(K + F) storage for K distinct fair destinations.
Peak memory and allocation counts are not measured.

## Reproduce

Use matching Swift 6.1-or-newer tools and a checkout containing the baseline
commit. The runner's older default baseline is the original main revision,
so **pass the follow-up baseline explicitly**:

```sh
python3 Benchmarks/PlaybackProgressReachability/run.py test --configuration debug --baseline-ref 4077f8ad538dd8ed911b38c9b300a98c787c5135 --output /tmp/progress-debug
python3 Benchmarks/PlaybackProgressReachability/run.py test --configuration release --baseline-ref 4077f8ad538dd8ed911b38c9b300a98c787c5135 --output /tmp/progress-release
python3 Benchmarks/PlaybackProgressReachability/run.py benchmark --rounds 10 --target-ms 100 --baseline-ref 4077f8ad538dd8ed911b38c9b300a98c787c5135 --output /tmp/progress-benchmark
```

Use a fresh output directory for every invocation. The runner snapshots the
actual source bytes before compiling. It uses Kyoto when available and
otherwise records the limitation before serialized direct builds in isolated
directories. `--swiftc` / `SWIFTC` and `--swift` / `SWIFT` select a toolchain.

The opt-in native workflow uses macOS 26 and Xcode 26.6. The runner also
supports Linux component research; every reported cohort identifies its
actual platform. The benchmark is not an automatic gate for unrelated
future edits because its comparison requires pinned, matching dependencies.

## Production sources and timing boundary

Both versions use complete production source. Shared `MediaTrack.swift`
and all fourteen playback-core files form separate optimized libraries.
Each variant builds all ten state-space files into its own optimized
library, then links the same independently optimized harness. Every
production dependency except `PlaybackProgressAnalyzer.swift` must match
the selected baseline. No copied analyzer or platform stub is substituted.

Prepared-graph workloads time the entire
`PlaybackProgressAnalyzer.analyze` call, including classification,
reachability, strongly connected components, report construction, and a
small result checksum. Graph construction, metadata, and full report
serialization remain outside those intervals. The end-to-end control
includes exploration and analysis.

| Workload | Purpose |
| --- | --- |
| `real-seek` | Actual ready-playing seek model, depth 4 |
| `real-eof-drain` | Actual playing-av EOF/drain model, depth 4 |
| `real-stop-shutdown` | Actual opening shutdown model, depth 5 |
| `end-to-end-stop-shutdown` | Complete exploration plus analysis for the same configuration |
| `synthetic-chain-forward` | 512 fair edges in forward order |
| `synthetic-chain-reverse` | The same chain in reversed edge order |
| `synthetic-sparse` | 2,047 transactions directly reaching one terminal; only one fair destination |
| `synthetic-dense` | 256 cyclic transaction vertices with 16 edges each and a terminal exit |
| `synthetic-all-settled` | 2,048 terminal vertices; both variants skip reachability |
| `synthetic-no-settled` | 2,048 transactions with no terminal/wait seed; both variants skip reachability |
| `synthetic-partial-settled` | One reachable transaction beside 2,046 closed transaction vertices |
| `synthetic-no-fair` | Unfair exits cannot establish fair reachability |

Real fixtures use deterministic limits of 2,000 states and 20,000 edges,
with wall-clock limits disabled and partial order reduction disabled. Their
actual counts, cutoffs, complete search summaries, and ordered graph
fingerprints accompany each observation. These are bounded fixtures.

The runner calibrates from one iteration and uses the same iteration count
for each variant. Final measurements use fresh serial processes and balanced
AB/BA pairs; each performs one warm-up operation. Ten rounds produce
240 final observations across twelve workloads. There is no percentage-based
timing gate and no outlier removal.

## Correctness and evidence

Before timing, both binaries emit 149 complete normalized report receipts:
the twelve timed fixtures, six real models at depth 3, three empty/singleton
cases, and 64 deterministic mixed graphs in both edge orders. Every report
field, stuck-state ID, and SCC member is compared. Only unordered SCC
representation is normalized. Each timing pair must also match graph
metadata, timing scope, checksums, and operation counts.

The current state-space suite contains 37 tests: the original 24, PR #174's
six regressions, and seven additional regressions. The latter include all
512 fair/unfair edge masks in both edge orders against an independent forward
path oracle. The full suite runs against both variants in debug and release.

See [RESULTS.md](RESULTS.md) for the final decision, every measured control,
source and host identity, and retained evidence. The report also records the
rejected guarded-scan candidate. Do not combine its observations with the
final array-index cohort or attribute the parent PR's gains to this change.


### Integrated current-support regression

Run the reviewed integration cohort without collecting new performance evidence:

```sh
python3 Benchmarks/PlaybackProgressReachability/test_policy.py
python3 Benchmarks/PlaybackProgressReachability/run.py regression \
  --baseline-ref 4077f8ad538dd8ed911b38c9b300a98c787c5135 \
  --output /tmp/playback-progress-regression-fresh
```

This explicit mode pins the historical analyzer and the reviewed PR229 analyzer
by SHA-256. It captures current production sources once and stages identical
non-focal support in both arms. Only the reviewed exact versions of
`PlaybackPartialOrderReducer.swift` and `PlaybackStateSpaceExplorer.swift` may
differ from historical support; all other support must remain byte-identical.
New source paths, changed pins, a replacement baseline, and a no-op candidate
fail before toolchain discovery or compilation.

Both arms execute the complete state-space test suite in debug and release,
then run the existing complete normalized graph/progress-report differential
and workload-list comparison. All existing harness graphs and controls remain.
Regression mode rejects timing options and partial variant/configuration
selection, and stops before calibration or measurement. Command elapsed-time
metadata remains operational provenance, not benchmark evidence. Its receipts
are regression-only and do not replace or update the committed historical
performance artifacts. Fresh output directories remain mandatory.

Pull requests use this regression route. Manual dispatch defaults to regression;
select `historical` to retain the original strict dependency-equality test and
timing experiment. The ordinary `test` and `benchmark` modes retain their strict
historical support policy and will reject integrated support drift.

The integrated candidate pin includes main's SCC outgoing-index reuse and dense
SCC bookkeeping, in addition to PR229's three predecessor-indexing edits.
The earlier candidate pin described pre-integration commit
`020cfc23e6749981909227a92dbab4a861b08f39`; it did not describe integrated head
`f18d8d3d83c092575ddcdb05b85d0756d496c562` or its CI merge
`50e1a0820d5f7f73734b56628c6824d0197df03b`. The corrected exact SHA-256 is
`ca3976b19fce3e96c5fa93edfa9ed54f6487609aa2190de1917eafce55e8e8de`.
The historical baseline analyzer remains unchanged, so this regression compares
the combined integrated focal changes against the historical oracle; it does
not isolate a new predecessor-indexing performance measurement. Policy tests
also stage actual checkout sources using the real pins, ensuring synthetic
controls cannot conceal a stale candidate pin.
