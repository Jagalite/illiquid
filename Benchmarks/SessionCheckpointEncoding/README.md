# Session checkpoint JSON encoding

## Decision: do not promote this candidate

The longer native confirmation did not reproduce a sufficiently consistent
production-save improvement. No PR was opened, and this experiment did not
change `main`. The candidate implementation remains in this research branch
to make the comparison reproducible; it is not a merge recommendation.

The decision criteria were recorded before retrieving confirmation output in
[`evidence/confirmation-plan.json`](evidence/confirmation-plan.json). In the
large plain workloads, median paired CPU reductions were only **1.43%** and
**1.34%**, with **8/12** and **9/12** winning pairs. Neither reached the practical
gate of at least 5% with at least 10/12 winning pairs. These thresholds are
consistency rules for this experiment, not statistical-significance claims.

Compatibility passed. The rejection concerns the performance evidence, not a
reproduced data-loss or restoration defect. A small benefit on some workloads
remains possible, but the initial larger gains are not justified as a stable
improvement in the production save path. No further repetitions were used to
search for a favorable result.

## Question and change

`AtomicPlaybackSessionStore.save` encodes the complete playlist on each session
checkpoint. At baseline `7f9ba073394b77a908e0589447c6edc8d10b832c`, it enables
`JSONEncoder.OutputFormatting.sortedKeys`, sorting object members throughout
the document. The candidate uses the encoder's default formatting.

The session reader addresses fields by name through `JSONDecoder`. Repository
consumers compare decoded records or inspect fields; no session byte hash,
signature, or canonical JSON contract was found. JSON object members are
unordered while arrays are ordered in [RFC 8259, section 1](https://www.rfc-editor.org/rfc/rfc8259.html#section-1).
The change intentionally makes object-key order unspecified. The schema,
values, playlist order, subtitle order, saved shuffle order, locking, directory
creation, and atomic replacement remain the same.

The controller checkpoints after at least ten seconds of position change and
on explicit playback/lifecycle operations. Encoding runs on the coalescing
writer queue. This experiment measures the encoding/save component, not the
entire checkpoint operation, UI latency, playback CPU, or battery life.

## Reproduce

From a checkout containing the baseline commit (use a full clone in CI):

```sh
python3 Benchmarks/SessionCheckpointEncoding/run.py \
  --pairs 12 --target-ms 500 --output /tmp/session-checkpoint-results
```

The output directory must be new or empty. Swift 6.1 or later is needed.
The macOS workflow uses the repository's Xcode 26.6 / macOS 26 configuration.
Standalone compilation explicitly targets macOS 26.0.

`--mode tests` runs compatibility tests against both variants in debug and
release. `--mode benchmark` runs timing and complete-payload comparisons.
Both execute by default. Linux runs replace only the inactive
`LifecyclePerformance.isEnabled` flag because the real instrumentation imports
macOS `os.signpost`; native runs use the real production instrumentation file.
All benchmark stores use explicit disposable paths.

## Method

- The frozen baseline store is checked byte-for-byte against its Git commit.
  Both variants use identical current production dependencies, whose hashes are
  recorded. The store and data models are separately compiled into optimized
  modules, then linked to the same driver without cross-module optimization.
- Eight workloads cover 0, 1, 24, 1,000, and 10,000 plain playlist items and 24,
  1,000, and 10,000 richer shuffled items with dates, two subtitles per item,
  Unicode, escaped characters, and saved base order. These are synthetic
  fixtures, not measured user playlist distributions.
- `save` times the actual production method, including locking, the existing
  directory-creation call, JSON encoding, and `.atomic` replacement. Three
  warmups create the directory/file; timings describe steady overwrites on the
  runner's temporary filesystem. Record construction, deduplication, reading,
  decoding, comparison, and cleanup are excluded.
- `encode` is a separate attribution kernel using the real Codable record and
  the two encoder configurations. Its results are not substituted for actual
  save timings.
- Each baseline/candidate observation runs in a fresh process. Pair order
  alternates. Baseline calibration selects one shared iteration count per
  workload; all calibration observations are retained. The harness captures
  elapsed time and process CPU time, and retains medians, ranges, and every
  paired percentage difference.
- Every observation decodes its output and compares the complete record with
  the input, including ordered arrays. Every timing pair also compares the
  complete parsed JSON documents and byte counts. Representative raw payloads
  from pair zero are retained; hashes and receipts are retained for all samples.
- Seven compatibility tests per variant/configuration cover the existing
  location/clear/sanitization/v1 behavior plus rich shuffled round trips,
  historical sorted documents, changed subsequent checkpoints, and preserving
  the previous valid file when encoding fails.

## Limits

Removing sorted keys does not reduce the number of bytes written. The complete
playlist is still serialized at every save. Large-fixture timings do not imply
the same saving for typical short playlists, where filesystem costs may dominate.
This does not measure `fsync`, crash durability, power loss, visible playback,
whole-player CPU, or shutdown time. Native macOS evidence is required for native
performance claims; Linux results are retained separately.

## Evidence

The runner writes `manifest.json`, `tests.json`, `observations.jsonl`,
`summary.json`, command/test logs, and representative payloads. The workflow
uploads these as `session-checkpoint-encoding-native`.

### Initial native sample

[Run 39844623385](https://github.com/Jagalite/illiquid/actions/runs/39844623385)
tested commit `224fc23b0dff728378d77591a5f229be36295892` on a virtual Apple M1,
macOS 26.6.2, Apple Swift 6.3.3. All seven tests passed in both debug and release
for both variants. All 128 complete-payload comparisons passed (256 timing
observations plus 16 calibration observations).

This sample used eight pairs targeting 80 ms per observation. Production-save
medians are below; positive reductions mean faster. Full results, including
all paired differences and encode-only observations, are in
[`evidence/native-initial`](evidence/native-initial).

| Playlist | Baseline save, ms | Candidate save, ms | Wall reduction | CPU reduction |
| --- | ---: | ---: | ---: | ---: |
| Empty / remote | 0.582 | 0.544 | 6.6% | -0.3% |
| 1 plain item | 0.525 | 0.540 | -2.9% | 6.6% |
| 24 plain items | 0.503 | 0.613 | -21.9% | -14.2% |
| 1,000 plain items | 3.176 | 2.908 | 8.4% | 8.9% |
| 10,000 plain items | 33.141 | 25.755 | 22.3% | 18.9% |
| 24 rich items | 0.835 | 0.760 | 9.0% | 14.1% |
| 1,000 rich items | 8.450 | 7.541 | 10.8% | 11.4% |
| 10,000 rich items | 113.679 | 105.181 | 7.5% | -6.7% |

The small-playlist apparent slowdown and mixed rich-playlist CPU results led
to one longer independent confirmation using twelve pairs targeting 500 ms.
No production code or fixtures changed for that confirmation, and the initial
observations remain retained.

### Longer native confirmation

[Run 39845750523](https://github.com/Jagalite/illiquid/actions/runs/39845750523)
tested `c98e29f874e6d6295f1940886849b35f11b3b28d` with the same virtual Apple M1,
macOS 26.6.2, and Apple Swift 6.3.3 configuration. The original and candidate
source hashes match those in the first native run. All seven compatibility
tests again passed in debug and release for both variants. All **192** complete
JSON comparisons passed, with equal payload sizes and full record round trips.
The run contains **384 timing observations plus 16 calibrations**.

The table reports marginal wall-time medians and the primary paired CPU
comparison. These are distinct summaries: the median of paired percentage
changes need not equal the ratio of two separate medians.

| Playlist | Baseline save, ms | Candidate save, ms | Median paired CPU reduction | Faster CPU pairs |
| --- | ---: | ---: | ---: | ---: |
| Empty / remote | 0.426 | 0.416 | 1.51% | 7/12 |
| 1 plain item | 0.388 | 0.367 | 3.94% | 10/12 |
| 24 plain items | 0.511 | 0.562 | 5.94% | 9/12 |
| 1,000 plain items | 2.997 | 2.983 | 1.43% | 8/12 |
| 10,000 plain items | 25.855 | 25.861 | 1.34% | 9/12 |
| 24 rich items | 0.517 | 0.531 | -1.34% | 5/12 |
| 1,000 rich items | 7.418 | 6.957 | 1.60% | 8/12 |
| 10,000 rich items | 73.005 | 72.315 | 0.97% | 7/12 |

Full medians, ranges, paired observations, execution-order splits, environment,
and hashes are retained in
[`evidence/native-confirmation`](evidence/native-confirmation). The archive
digest in `run.json` was verified after downloading the CI artifact.

The apparent 22.3% initial wall-time saving for 10,000 plain items became
effectively flat in confirmation (25.855 versus 25.861 ms). Rich 10,000-item
CPU medians still differed by execution order: -0.14% with baseline first
versus +4.11% with candidate first. Small controls remain variable; no claim
of zero overhead or universally faster small saves is warranted.

Across both native runs, **640 timing observations and 320 complete JSON
comparisons** were collected, plus 32 calibrations. They are reported
separately rather than pooled. The complete app build and native playback
suite were not run for this rejected candidate; passing these component
tests is not full application qualification.

### Portable preliminary run

The initial Linux run passed all seven tests for both variants in debug and
release. It stopped during encode-only measurements because the shared disk
filled; no production-save measurements completed. Those partial, noisy
timings are inconclusive and do not justify a performance claim. Receipts are
in [`evidence/linux-incomplete`](evidence/linux-incomplete).
