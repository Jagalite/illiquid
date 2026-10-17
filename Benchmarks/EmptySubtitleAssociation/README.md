# Empty external-subtitle association research

Compare the complete `ExternalSubtitleMatcher.associate` call and the complete,
pure `FolderPlaylistDiscovery.makePlaylist` model construction before and after
the no-subtitle fast path. Baseline: `68274d1b09dcc866296321a5a8858efc297c4f19`.
All seven original selected core sources are retained verbatim with SHA-256 and
Git blob fingerprints. The runner uses the frozen matcher for the baseline, the
current matcher for the candidate, and the same six current production helpers
for both. Manifests verify shared-source equality and record each source's match
to the frozen original. At the initial research revision all six helpers match
the pinned originals. Later helper changes therefore remain usable while still
isolating the matcher comparison; consult the source manifests for each run.

## Reproduce

Requires Python 3.10+ and Swift 6.1+. Native macOS is the qualification platform.
Each output directory must be new or empty.

```sh
python3 Benchmarks/EmptySubtitleAssociation/run.py test --configuration debug --output /tmp/empty-subtitle-debug
python3 Benchmarks/EmptySubtitleAssociation/run.py test --configuration release --output /tmp/empty-subtitle-release
python3 Benchmarks/EmptySubtitleAssociation/run.py benchmark --pairs 6 --target-ms 60 --output /tmp/empty-subtitle-timing
```

`test` copies the full, unmodified matcher, discovery, filesystem regression,
and temporary-directory test sources into isolated baseline and candidate Swift
packages. `benchmark` compiles each variant's exact core sources into its own
optimized static module, then separately compiles the same driver. The compiler
cannot optimize through a substituted implementation or an inlined copied kernel.
On macOS, the runner uses `xcrun` and records the selected SDK and Xcode version.

## Workloads and validation

The default 20 cells include both operations with no subtitles at 0, 1, 8, 1,000,
and 10,000 ASCII media URLs; long Unicode names at 8, 1,000, and 10,000; and
nonempty matched and unsupported-subtitle controls at 128 media URLs.
Inputs use deterministic permutations and fixed, partially populated metadata
dates. No fixture files are created for these model timings.

Before timing, 72 differential outputs cover original URL keys, duplicates,
unsupported and nonlocal URLs, Unicode, reversed input, matched subtitles, and
full playlist metadata. An independent oracle requires the complete set of
original input URL keys with empty arrays when there are no subtitles. Matched
controls independently require each exact subtitle to be assigned. Repository
tests separately exercise cancellation and real temporary-directory discovery.

Both variants are calibrated in fresh processes; every calibration observation
is retained separately. A shared iteration count aims for the slower calibration
to reach the requested duration, capped by `--max-iterations`. The six paired
observations alternate AB/BA order, use fresh processes and three or fewer warmup
iterations, and retain every completed observation. Loop counts are the same
across all processes in each cell. Calibration is excluded from the summary.
Summaries include separate variant medians/minima/maxima, each within-pair
reduction, median within-pair reduction, and the number of improved pairs for
both wall and process CPU time. This analysis is specified before collecting data.

Fixture generation, correctness checks, full result serialization, URL readback,
and metadata extraction occur outside the timer. Every iteration consumes the
returned count; the final complete association map or playlist is read back and
compared across both variants and every process. Core and driver compilation are
separate. Result destruction when replacing the previous loop result occurs
inside the interval; the final result remains alive until readback.

The runner records wall and process CPU time, raw `measurements.jsonl`, separate
`calibration.jsonl`, complete canonical result receipts, subprocess logs, exact
source/driver/binary fingerprints, and platform/compiler/SDK provenance.
Repeated timing logs retain all scalar fields and the full result's SHA-256;
one full result per cell is retained after complete in-memory comparison of every
process result. This keeps large URL lists out of repeated logs. Final
validation reads the stored rows, outputs, source bytes and logs back from disk,
and checks the actual AB/BA identities and ordering. JSON summaries are atomically
written and are marked incomplete until all validation succeeds.

These are means per process and medians across processes, not interaction-latency
percentiles. `makePlaylist` includes existing URL normalization, natural sorting,
association, item creation and deduplication. It excludes filesystem enumeration,
metadata I/O, media opening, decode, and visible UI work. No end-to-end playback,
NAS, frame-rate, energy, or resident-memory improvement follows from this probe.
