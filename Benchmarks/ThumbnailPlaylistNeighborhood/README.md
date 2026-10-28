# Background thumbnail playlist-neighborhood preparation

## Finding and change

At baseline `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`, `ThumbnailBackgroundScheduler.runPass` maps the entire playlist to a new URL array before locating the current video and taking at most four neighbors on each side. That eager map runs even when the current URL is absent or nil. This work happens on the main actor before ranking moves to its existing background task. The affected path is library thumbnail preparation enabled by the background-generation preference.

The candidate uses the synchronous `ThumbnailPlaylistNeighborhood` helper to find the first matching entry directly in the existing playlist and materialize only the requested window. The helper returns at most nine URLs and their distances. It retains no playlist or playlist slice after returning. Ranking, deduplication, the pass cursor, cancellation, background admission, decoding, and cache policies are unchanged.

The preserved contract includes direct Foundation URL equality, the first matching occurrence as the anchor, original URL order and duplicates in the window, and the original dictionary's last-write-wins distance when a duplicate URL occurs in that window. An empty playlist, nil current URL, or absent current URL produces an empty neighborhood.

For a playlist with `N` items and an anchor at index `A`, the old preparation creates `N` mapped URL values before searching. The new preparation examines only the prefix needed to find the anchor and materializes a window `W <= 9`. Missing selections still require a linear search; nil selections return immediately. This changes the neighborhood calculation's auxiliary storage from input-sized to bounded; it does not change the space used by the player's source playlist or by unrelated scheduler collections.

Swift documents [`map`](https://developer.apple.com/documentation/swift/sequence/map%28_%3A%29) as producing an array in linear time. Passing the existing playlist to a read-only helper relies on the standard library's documented [collection storage sharing](https://docs.swift.org/swift-book/LanguageGuide/ClassesAndStructures.html), rather than making a second mapped array.

## Why the output contract is preserved

For a non-nil current URL, both versions select the smallest index `i` for which `playlist[i].url == current`. Mapping stored URL values first does not change that equality comparison or the index. Both then use the same half-open index range, `max(0, i - 4)..<min(count, i + 5)`.

Appending those indices in ascending order produces the same URL array as copying the old slice, including repeated URLs. Assigning each distance in the same order also preserves the original last-write-wins dictionary behavior for duplicate URLs; this matters because a repeated occurrence of the current URL can leave a nonzero distance. Nil and missing selections yield the same empty outputs. Dictionary iteration order is not used by the scheduler; it looks up each candidate's distance by URL.

The helper is synchronous and does not retain its input or a slice in the returned value. Candidate construction remains on the main actor before the existing suspension point, so this change adds no actor reentrancy, invalidation, or cache lifetime to reason about.

## Measurement scope

This experiment measures playlist-neighborhood construction plus the same result-consumption work for both versions. Fixture construction is outside the timed interval, and each measurement process performs eight warmup calls. It does not measure the rest of candidate collection, ranking, an entire background pass, decoder work, visible playback, energy, or total application memory.

The removed full-playlist URL array has an input-size-proportional element-storage cost. The evidence reports the element count and the measured `MemoryLayout<URL>.stride` separately from timings. Their product is a structural payload calculation, not a measured heap allocation or RSS reduction: it excludes array headers, allocator rounding, and the URL objects or strings already owned by the playlist. The nine-value bound describes stored output values; [`reserveCapacity`](https://developer.apple.com/documentation/swift/array/reservecapacity%28_%3A%29) can allocate more capacity than requested. Compiler lifetime decisions also mean this experiment does not claim that the old array necessarily survives every subsequent suspension.

## Validation

### Portable component: passed

The [portable qualification job](https://github.com/Jagalite/illiquid/actions/runs/40637991063/job/122649304501) completed successfully for candidate `43bc99173cce87addd747d57f0919420c34e1317` against baseline `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`. The checkout was clean. This was Ubuntu 24.04.5, Linux x86_64, glibc 2.39, and Swift 6.4; the CPU model was not recorded. These are portable component results, not macOS application timings.

- All six shared tests passed for both implementations in debug and release: four runs, 24 test executions. The runner requires both a zero exit code and a Swift Testing receipt stating that six tests passed.
- All 17 canonical outputs matched exactly, including URL order and distance entries.
- All 204 release measurements completed and passed the per-sample result checks.
- The source integration guard passed, including the unchanged scheduler body after candidate construction.

The table uses microseconds per call. “Reduction” is the median percentage reduction across the six paired samples, rather than a percentage calculated from the separate medians.

| Playlist items / selection | Baseline median (µs) | Candidate median (µs) | Paired median reduction | Candidate faster pairs |
| --- | ---: | ---: | ---: | ---: |
| 0 / nil | 0.0244 | 0.0209 | 14.59% | 6/6 |
| 1 / first | 0.2732 | 0.2856 | -5.05% | 0/6 |
| 32 / nil | 0.4646 | 0.0201 | 95.69% | 6/6 |
| 32 / first | 1.6421 | 0.8127 | 51.31% | 6/6 |
| 32 / middle | 2.9335 | 1.5949 | 45.15% | 6/6 |
| 32 / last | 2.0426 | 1.1870 | 42.91% | 6/6 |
| 32 / missing | 0.7255 | 0.2901 | 60.64% | 6/6 |
| 2,048 / nil | 23.0788 | 0.0203 | 99.91% | 6/6 |
| 2,048 / first | 25.8943 | 0.7675 | 97.09% | 6/6 |
| 2,048 / middle | 34.9088 | 9.8906 | 71.93% | 6/6 |
| 2,048 / last | 42.6879 | 21.1613 | 51.02% | 6/6 |
| 2,048 / missing | 38.3019 | 15.8101 | 58.65% | 6/6 |
| 100,000 / nil | 1143.7852 | 0.0203 | 99.9982% | 6/6 |
| 100,000 / first | 1142.6898 | 0.8098 | 99.93% | 6/6 |
| 100,000 / middle | 1977.2022 | 542.8664 | 71.80% | 6/6 |
| 100,000 / last | 4554.1012 | 2204.1230 | 51.26% | 6/6 |
| 100,000 / missing | 1900.5255 | 793.9791 | 58.15% | 6/6 |

Sixteen workloads improved in all six pairs. The singleton regressed in all six: 273.16 ns to 285.64 ns, about 12.49 ns additional median time, with a 5.05% paired median regression. This small absolute cost is retained and reported; the optimization is not universally faster. No significance test or cross-machine generalization is claimed.

For the 100,000-item stress case, the measured URL stride was 16 bytes. Removing the full projection eliminates 100,000 source-level URL elements, a derived 1,600,000-byte payload (about 1.53 MiB), while the returned array contains at most nine values. For 2,048 and 32 entries, the corresponding derived payloads are 32,768 and 512 bytes. These figures do not establish a process-memory reduction.

### Native application: pending

The [macOS component job](https://github.com/Jagalite/illiquid/actions/runs/40637991063/job/122649304756) and [application integration job](https://github.com/Jagalite/illiquid/actions/runs/40637991063/job/122649304738) were still queued when these receipts were collected. This work remains a draft pending native compilation and focused application tests. No native timing, full-application test pass, live UI, playback, or energy result is claimed.

The attached execution workspace could not start, so no local execution is claimed. The workflow records Kyoto's absence before direct compilation in its isolated hosted runner.

### Durable evidence

The committed [evidence directory](evidence/linux-x86_64-20261028/) contains the final [environment and source hashes](evidence/linux-x86_64-20261028/environment.json), [test receipts](evidence/linux-x86_64-20261028/tests.json), [canonical outputs](evidence/linux-x86_64-20261028/canonical.json), [summary](evidence/linux-x86_64-20261028/summary.json), all 17 calibration records, and all [204 raw measurement rows](evidence/linux-x86_64-20261028/measurements.jsonl). The JSON was recovered directly from the successful job's evidence markers, preserving the original integer text, including UInt64 checksums. The [CI receipt](evidence/linux-x86_64-20261028/ci-receipt.json) links the run, jobs, and artifact.

The [uploaded artifact](https://github.com/Jagalite/illiquid/actions/runs/40637991063/artifacts/12794810871) additionally includes command logs and source snapshots; GitHub retains it for 14 days. The committed data is the durable record. This report and its evidence are a documentation-only follow-up to the tested candidate commit.


## Reproduce

Run from a checkout containing the candidate and the baseline Git commit:

```sh
python3 Benchmarks/ThumbnailPlaylistNeighborhood/run.py --output /tmp/illiquid-thumbnail-neighborhood
```

Where the repository's shared Kyoto queue is available, submit that command through the queue instead, and inspect its job status, logs, and completion receipt:

```sh
python3 /Volumes/seed1/Projects/kyoto/kyoto.py submit -- python3 Benchmarks/ThumbnailPlaylistNeighborhood/run.py --output /tmp/illiquid-thumbnail-neighborhood
```

The GitHub workflow checks that Kyoto is unavailable before compiling directly in separate ephemeral runner checkouts. It also configures a build of the production application graph and focused thumbnail scheduling and policy regressions, whose completion status is reported separately.

## Method and interpretation

The isolated package compiles the production helper and three unchanged production Core dependencies (`FolderPlaylist.swift`, `NaturalFilenameOrdering.swift`, and `NormalizedFileURL.swift`). Its baseline helper contains the exact map/search/window/distance blocks extracted from the pinned scheduler; only the input receiver and a wrapper differ. Extraction guards reject a changed baseline, and an integration guard checks that the production scheduler invokes the helper before suspension and leaves its remaining pass body unchanged.

Both variants run the same six Swift Testing methods in debug and release: 24 test executions across four successful runs. Complete URL order and sorted distance-table output are compared for 17 workloads: an empty selection, a singleton, and 32-, 2,048-, and 100,000-item playlists with nil, first, middle, last, or missing selection.

Release measurements use six paired samples per workload, alternating baseline/candidate and candidate/baseline order and rotating workload order. Each variant/workload sample runs in a fresh process, performs eight warmups, and uses a separately calibrated iteration count targeting a 30 ms batch. The runner retains all 204 measurements and all calibration attempts. Each timed result is consumed identically and checked against the canonical receipt; fixture creation, JSON output, and process startup are excluded. A [`withExtendedLifetime(fixture)`](https://docs.swift.org/latest/documentation/swift/withextendedlifetime%28_%3A_%3A%29-59dz3/) barrier after both clocks stop also excludes input teardown. These are warm repeated operations on synthetic file URLs, not measurements of cold UI interactions. The 100,000-item playlist is a stress case; no assertion is made about users' actual playlist-size distribution.

Tables report median nanoseconds per call and the median reduction across paired samples. The latter can differ from the percentage computed from the two separate medians. Process CPU and wall times are retained separately; no timing threshold is used as a correctness gate. Fresh processes and paired order reduce several sources of bias, but a single hosted runner remains a limited sample and does not characterize every Mac or real media library.

The separate application job is configured to build the real package with its pinned native SDK and run the focused neighborhood, thumbnail-policy, scheduling-regression, and fixture-independent scheduler tests. Its qualification status is reported separately from the isolated component measurements.

## Concurrent work

[PR #132](https://github.com/Jagalite/illiquid/pull/132) and [PR #135](https://github.com/Jagalite/illiquid/pull/135) independently address the same neighborhood allocation. This branch is an alternative qualification of that change. Maintain a single production implementation when reconciling these PRs; this report does not count their measurements as evidence from this branch.

