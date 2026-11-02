# ASCII file identity keys and playlist lookup

**Qualification status:** Linux measurement and correctness work is complete.
Native macOS qualification remains queued, so this is a research draft with
an outstanding application-platform gate.

## Change and compatibility boundary

The research baseline is main commit
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`. At that revision,
`NormalizedFileURL.persistenceKey(for:)` obtains its key by calling
`normalize(url)?.path`. Each supported input is validated and standardized,
Unicode-normalized, converted into a new file URL, and immediately converted
back to a path string. `FolderPlaylist.index(of:)` repeats that operation for
every inspected item.

The candidate returns the validated, standardized path directly when it has
contiguous ASCII storage and an ordinary absolute-path representation. It
retains the existing Foundation constructor for Unicode or noncontiguous
storage, embedded NULs, leading double slashes, file-reference paths, and
unusual trailing slashes. The public normalization operation and authority
validation remain unchanged. The change adds neither an identity cache nor a
filesystem query.

The Unicode fallback is necessary for exact compatibility: Foundation's Darwin
file-path conversion can change the Unicode byte representation (see the
[Swift 6.3.2 URL constructor](https://github.com/swiftlang/swift-foundation/blob/swift-6.3.2-RELEASE/Sources/FoundationEssentials/URL/URL_Swift.swift)
and [Darwin filesystem conversion](https://github.com/swiftlang/swift-foundation/blob/swift-6.3.2-RELEASE/Sources/FoundationEssentials/String/String%2BInternals.swift)). Swift String
canonical equality does not prove that persisted key bytes remain equal.
Both the regression suite and differential driver compare optional UTF-8
bytes against the original construction path.

Only `Sources/IlliquidCore/Utilities/NormalizedFileURL.swift` changes production
behavior. The frozen playlist and sorting sources are byte-identical in both
benchmark variants.

## Measured operation

The benchmark measures warm persistence-key creation and actual
`FolderPlaylist.index(of:)` calls. The full playlist lookup includes key
creation for every scanned item and query, equality comparisons, and loop
control. Playlist construction/sorting, fixture generation, warmup, full
output receipts, and validation are outside both timers. Result consumption
and the measured batch's native autorelease-pool drain are inside both timers.

Seventeen workloads include tiny, ordinary, long, aliased, Unicode, mixed,
and rejected URLs; empty, single-item, and eight-item playlists; first,
middle, last, and missing lookups in 1,000-item playlists; and Unicode and
rejected-query playlist controls. Their hit positions are asserted
independently of the baseline/candidate comparison.

Each workload has 12 adjacent, balanced AB/BA pairs in fresh processes.
Calibration targets 250 ms of baseline process CPU and assigns equal work
to both variants. Case order is shuffled with a fixed seed. All observations
are retained. Percentages are medians of paired changes; they need not equal
the percentage change between the separate baseline and candidate medians.

The modules and driver compile separately with optimization. Swift's default
cross-module optimization is enabled. Executable inspection confirms retained
production calls inside the measured Linux loops and confirms warmup before
the timer boundaries. The original Linux manifest described this boundary as
"without cross-module optimization"; the compiler-plan receipts and
`executable-audit.json` establish the more precise description above. That
wording has been corrected for future runs without changing compiler flags,
production sources, or measured observations.

## Linux qualification

Swift 6.3.2 on Linux x86_64, AMD EPYC 9V74; 408 observations in 204 pairs.
The complete 75,220-case differential passed, including 43,909 rejected
inputs. All 17 full key/item/index receipts matched. Both baseline and
candidate passed the same 34 focused tests in debug and release.

An independent audit checked all 485 command receipts, source and executable
hashes, calibration choices, operation counts, checksums, pair scheduling,
raw observations, reported statistics, and bootstrap intervals. No observations
were discarded, commands failed, or calibrations hit their operation cap.

| Workload | Baseline CPU (µs/op) | Candidate CPU (µs/op) | Paired CPU change | Paired wall change | Faster CPU pairs |
| --- | ---: | ---: | ---: | ---: | ---: |
| `keys-aliases-256` | 6.724 | 3.023 | -52.85% | -53.00% | 12/12 |
| `keys-ascii-256` | 5.869 | 2.283 | -60.93% | -59.96% | 12/12 |
| `keys-late-unicode-256` | 9.960 | 10.411 | +4.68% | +3.86% | 4/12 |
| `keys-long-ascii-256` | 16.433 | 4.539 | -68.14% | -68.21% | 12/12 |
| `keys-mixed-256` | 6.918 | 4.572 | -30.76% | -30.63% | 12/12 |
| `keys-rejected-256` | 0.374 | 0.391 | +0.92% | -4.24% | 6/12 |
| `keys-tiny-ascii` | 2.926 | 1.376 | -49.77% | -49.69% | 12/12 |
| `keys-unicode-256` | 7.335 | 8.006 | +9.93% | +10.20% | 5/12 |
| `playlist-empty` | 0.015 | 0.014 | -3.25% | -2.22% | 7/12 |
| `playlist-first-1000` | 11.906 | 4.689 | -59.57% | -59.21% | 12/12 |
| `playlist-last-1000` | 5799.560 | 2323.161 | -60.08% | -60.11% | 12/12 |
| `playlist-middle-1000` | 3040.623 | 1288.733 | -60.09% | -60.18% | 12/12 |
| `playlist-miss-1000` | 6459.550 | 2624.414 | -61.88% | -61.93% | 12/12 |
| `playlist-rejected-query-256` | 7.759 | 3.305 | -55.34% | -55.34% | 12/12 |
| `playlist-single-hit` | 13.863 | 4.578 | -63.27% | -64.19% | 12/12 |
| `playlist-small-last` | 63.224 | 21.792 | -67.26% | -67.30% | 12/12 |
| `playlist-unicode-last-256` | 1804.012 | 1854.585 | +4.74% | +4.02% | 4/12 |

All ASCII and mixed-key workloads, and all nonempty ASCII playlist workloads,
favored the candidate in every pair. The ordinary 1,000-item middle/last/miss
lookups improved by approximately 60–62% in this component measurement.

The early-Unicode fallback control increased by 9.93% median paired CPU,
with a median paired increase of 0.728 microseconds per key. Its bootstrap
interval spans -12.74% to +21.62%, and the candidate was faster in 5 of 12
pairs. These samples establish neither fallback neutrality nor a robust
regression. The late-Unicode and Unicode-playlist medians increased by 4.68%
and 4.74%, respectively. All of these observations are retained; the favorable
ASCII results do not erase them.

## Native macOS qualification

The first native attempt, [Actions run 40634917579](https://github.com/Jagalite/illiquid/actions/runs/40634917579),
failed while compiling the new test fixtures against the baseline: the
Core Foundation Create API returned an unmanaged URL requiring explicit
ownership conversion. No native timing took place. The failed compilation
and environment are retained in [the initial native evidence](../Benchmarks/FileIdentityKeys/evidence/native-initial/run.json).
The test and differential driver were corrected without changing production
code or the timed driver.

Native qualification is being rerun against the exact candidate in
[Actions run 40636149971](https://github.com/Jagalite/illiquid/actions/runs/40636149971).
This section will be completed from the actual native receipts before the
research is described as qualified for the application platform.

## Related parallel work

Three other branches appeared during this investigation that optimize the
same helper: [FileIdentity](https://github.com/Jagalite/illiquid/blob/e12ba6e856388e8984b078eb77ebf2f16e946d96/Benchmarks/FileIdentity/README.md),
[LocalFileIdentity](https://github.com/Jagalite/illiquid/blob/635afff039c4a506d19b69a8cc0c26279a81b084/Benchmarks/LocalFileIdentity/README.md),
and [NormalizedFileIdentity](https://github.com/Jagalite/illiquid/blob/6ef890adadce1e4b10eacd6997ebee436fbae9fe/Benchmarks/NormalizedFileIdentity/README.md).
These changes affect the same production lines and should be reviewed as
alternatives. [PR #144](https://github.com/Jagalite/illiquid/pull/144) now presents
the FileIdentity variant, and [PR #151](https://github.com/Jagalite/illiquid/pull/151)
presents another file-identity study. This candidate specifically requires already-contiguous UTF-8
storage before scanning for ASCII, retaining the original construction path
when the storage is unavailable. The other candidates use different byte and
path-shape admission rules. This study compares only this candidate with the
frozen main revision; it does not rank the parallel implementations.

## Reproduction and limits

See [the benchmark instructions](../Benchmarks/FileIdentityKeys/README.md) for
commands, the frozen source manifest, measurement boundaries, and artifact
layout. Use Kyoto for builds when it is available; the isolated hosted workflow
records that the shared queue is unavailable and runs builds serially.

Process CPU excludes time spent descheduled but remains sensitive to frequency,
cache state, and host load. The bootstrap intervals describe the retained
samples, not every device or workload. This study does not measure filesystem
discovery, persistence-write latency, whole-player CPU or memory, interactive
UI latency, or playback frame rate. The lookup algorithm remains linear in
the number of inspected playlist items.
