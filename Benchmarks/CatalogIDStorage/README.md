# Catalog-ID storage during metadata merging

Media metadata is reused across the files in a folder. The old merge path used
provider-set construction, filtering, and array concatenation even when one
input had no IDs. Those cases need no provider comparison and can return the
existing array, preserving Swift's copy-on-write storage.

The production change adds a private merge helper used by
`MediaMetadataHints.overriding` and `RecognizedMediaName.applying`. If either
ID array is empty, it returns the other array. When both contain IDs, it uses
the original provider-replacement algorithm.

## Production path

`MediaSidecarReader.recognize` combines folder NFO/PlexMatch metadata, an optional
episode mapping, and per-file metadata before applying the result to filename
evidence. These operations commonly merge IDs with an empty array:

- The first folder metadata is applied to an initially empty set of hints.
- A PlexMatch episode mapping supplies episode identity and inherits the series
  catalog IDs from its surrounding metadata.
- A filename without explicit catalog IDs receives the IDs supplied by sidecars.

The [sidebar's recursive media loader](../../Sources/IlliquidApp/UI/SourcesSidebar.swift)
stores the recognized metadata in its retained entry snapshot.
[Display-row projection](../../Sources/IlliquidApp/UI/SourceTreeProjectionInput.swift)
carries that metadata into rows, and
[the browser filter](../../Sources/IlliquidApp/UI/SourceBrowserFilter.swift) caches
those rows and uses catalog IDs for search. Sharing can therefore persist beyond
the lifetime of the sidecar reader. This is a mechanism established from the
call path; the experiment below measures component batches, not a full UI scan.

The optimization lets the resulting items share the same ID buffer until a
caller mutates one of the arrays. Swift preserves independent array values
through copy-on-write, as documented in Apple's
[Array reference](https://developer.apple.com/documentation/swift/array).
Only the ID array is shared; the helper does not retain a sidecar reader,
metadata object, or new cache.

## Behavior and baseline

The existing content-type and identity-change gates execute before the helper.
Provider replacement, ID ordering, duplicate IDs, and all other metadata fields
keep their existing behavior. In particular, switching between movie and
episode identities still discards the old identity's IDs.

`baseline/manifest.json` pins the three unchanged original source files to
[`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`](https://github.com/Jagalite/illiquid/commit/ea2ff568237e2667f7b1aeee67b11a44ebe95b72).
Each file has a Git blob SHA and a SHA-256 digest, checked before compilation.
Baseline and candidate are built separately from complete production sources.

The regression suite checks empty-sided merges, provider conflicts, ordering and
duplicates, unusual public-API ID strings, content-type transitions, and
mutation isolation after storage sharing. Before measuring either implementation,
the experiment compares complete canonical edge-case outputs and fingerprints of
every output in each benchmark cohort.

## Reproduction

Use the repository's Kyoto queue where it is available:

```sh
python3 /Volumes/seed1/Projects/kyoto/kyoto.py submit -- \
  python3 Benchmarks/CatalogIDStorage/run.py \
  --output /tmp/catalog-id-storage --mode all --pairs 12 --target-ms 250
```

Where Kyoto is unavailable, including the isolated GitHub Actions runner, run the
same Python command directly after noting that limitation:

```sh
python3 Benchmarks/CatalogIDStorage/run.py \
  --output /tmp/catalog-id-storage --mode all --pairs 12 --target-ms 250
```

Use a new output directory for each run. The component harness requires Swift
6.1 or newer and builds the selected Foundation-only sources without the app's
native playback dependencies. The workflow records test logs, source and binary
hashes, compiler/host details, calibration, raw paired observations, and summary.

## Interpretation

The measurement targets metadata construction and retained metadata arrays.
Each case uses 12 balanced baseline/candidate pairs in fresh processes. The two
release builds are calibrated separately toward 250 ms of process CPU work per
observation, then compared using time per identical-size output batch. The
measured loop constructs, consumes, and releases complete batches. Input setup,
canonicalization, and JSON formatting run outside that interval. Wall time is
also recorded.

Memory samples are separate from timing samples. They compare allocator-reported
bytes before construction and while the result cohort is held alive, with the
same inputs alive in both builds. The probe uses Darwin's
`malloc_zone_statistics(NULL).size_in_use` or glibc's
`mallinfo2().uordblks + hblkhd`. These are allocator measurements, not resident
memory or allocation-event counts. The after-release sample is diagnostic:
allocator and Foundation caches can affect it, so it is not a leak test.

Common workloads use one or three catalog IDs; larger arrays are explicit stress
cases. The direct API cases use fixed input arrays. The Plex cases create their
ID arrays through runtime parsing, so `plex-1` and `plex-3` are the representative
production-path comparisons. They reuse a parsed index of 128 episode mappings
across 4,096 outputs. `plex-3-large` retains 16,384 projections from that bounded
index; it does not parse a 16K-entry sidecar. Controls cover empty arrays and
nonempty arrays requiring provider replacement. Retained heap is measured while
the full result cohort remains alive, with equivalent baseline and candidate
outputs.

These component measurements do not establish a change in decoding speed, frame
rate, or the memory footprint of the complete running player. Live playback and
UI behavior are outside this experiment.

Sharing also preserves an input array's existing capacity. A public-API caller
that supplies a heavily over-reserved or mostly emptied array can keep its spare
capacity alive through the result; the old filtering path could compact it.
The fixtures model the small populated ID arrays produced by sidecar metadata,
so a lower retained heap here is not a claim that every possible caller-supplied
array uses less memory.

## Results

### Qualification and environment

The [Ubuntu job](https://github.com/Jagalite/illiquid/actions/runs/40637136248/job/122646589921)
completed successfully on 2026-10-28. It compared the pinned baseline with
candidate commit
[`43cbf1089543d15cda5ef2d51c0ca38c8bdbbae6`](https://github.com/Jagalite/illiquid/commit/43cbf1089543d15cda5ef2d51c0ca38c8bdbbae6),
using Swift 6.4 release optimization on x86-64 Ubuntu 24.04, glibc 2.39, and an
AMD EPYC 7763 host.

All 35 component tests passed in each of baseline debug, baseline release,
candidate debug, and candidate release: 140 test executions, including the nine
new catalog-ID regression tests. The 11 canonical API cases and all 12
whole-cohort fingerprints matched. The original and candidate parity files are
byte-identical.

The run contains 288 timing observations and 288 separate memory observations.
Every measured CPU interval lasted 253.374–305.420 ms. Source hashes, raw paired
samples, calibration, and result summaries are committed below. An independent
review reproduced the paired medians, balanced ordering, normalizations, and
headline bootstrap intervals from those raw samples.

The [macOS 26 job](https://github.com/Jagalite/illiquid/actions/runs/40637136248/job/122646589644)
was still queued when this report was written. The results here qualify the
portable component; no macOS measurement, full-player build, or live playback
qualification is claimed.

### Representative parsed-metadata results

For 4,096 mapped outputs with three inherited IDs, median CPU time fell from
**7.660 ms to 2.120 ms per batch**: **72.3% lower**, or about **3.61× faster**.
Allocator-reported retained storage fell from **1,211,504 to 753,552 bytes**,
saving **457,952 bytes (447.2 KiB), or 37.8%**.

With one inherited ID and the same output count, CPU time fell from
**4.116 ms to 2.116 ms** (**48.6% lower**) and retained storage fell from
**1,015,504 to 753,360 bytes**, saving **262,144 bytes (256 KiB), or 25.8%**.

Both parsed cases improved in all 12 timing pairs and all 12 memory pairs.
The descriptive 95% bootstrap intervals for the paired candidate/baseline CPU
ratio were **0.5113–0.5200** for one ID and **0.2764–0.2780** for three IDs.
These intervals describe this runner's samples, rather than the range of
performance across machines.

The 16,384-output three-ID stress case saved **1,834,208 bytes (1.75 MiB)** of
retained storage and reduced median CPU time from **30.592 ms to 8.422 ms**.
Its mapping index remains bounded at 128 entries.

### All measured cases

Except for `plex-3-large`, each batch contains 4,096 outputs. CPU reductions
below compare the two sample medians. Exact paired ratios, confidence intervals,
wall times, heap ranges, and release diagnostics are in the summary JSON.

| Case | Type | CPU ms/batch, baseline → candidate | CPU reduction | Held heap bytes, baseline → candidate |
| --- | --- | ---: | ---: | ---: |
| `plex-1` | Parsed Plex | 4.116 → 2.116 | 48.6% | 1,015,504 → 753,360 |
| `plex-3` | Parsed Plex | 7.660 → 2.120 | 72.3% | 1,211,504 → 753,552 |
| `plex-3-large` | Parsed Plex, 16K stress | 30.592 → 8.422 | 72.5% | 4,848,752 → 3,014,544 |
| `override-inherit-1` | Fixed-input API | 3.814 → 1.782 | 53.3% | 1,015,568 → 753,440 |
| `override-inherit-3` | Fixed-input API | 7.361 → 1.786 | 75.7% | 1,211,424 → 753,440 |
| `override-first-3` | Fixed-input API | 8.762 → 1.787 | 79.6% | 1,145,904 → 753,440 |
| `apply-inherit-3` | Fixed-input API | 5.773 → 0.246 | 95.7% | 1,146,144 → 688,176 |
| `apply-first-3` | Fixed-input API | 6.986 → 0.246 | 96.5% | 1,080,720 → 688,176 |
| `override-replace-3` | Provider-replacement control | 10.296 → 10.175 | 1.2% | 1,211,424 → 1,211,408 |
| `override-empty` | Empty-ID control | 1.975 → 1.792 | 9.3% | 753,408 → 753,392 |
| `override-kind-change` | Identity-change control | 0.686 → 0.607 | 11.6% | 491,568 → 491,568 |
| `override-inherit-64` | 64-ID synthetic stress | 75.798 → 1.778 | 97.7% | 5,144,496 → 753,472 |

The provider-replacement control showed no observed regression: retained heap
was essentially unchanged, and its small CPU difference is supporting control
evidence. The fixed-input API and 64-ID stress timings are not estimates of
application-wide speedup.

After-release allocator differences are diagnostic. In the three-ID Plex case,
the candidate had a 112-byte residual; the 16,384-output case had the same
112-byte residual. This fixed difference does not scale with the retained output
count and is distinct from the much larger held-batch savings.

### Permanent evidence

- [Environment, source hashes, and binary hashes](evidence/run-40637136248-ubuntu/manifest.json)
- [Test configurations and log hashes](evidence/run-40637136248-ubuntu/tests.json)
- [Parity receipt](evidence/run-40637136248-ubuntu/parity.json), [baseline records](evidence/run-40637136248-ubuntu/baseline-parity.json), and [candidate records](evidence/run-40637136248-ubuntu/candidate-parity.json)
- [All case summaries](evidence/run-40637136248-ubuntu/summary.json) and [case definitions](evidence/run-40637136248-ubuntu/cases.json)
- [Raw timing pairs](evidence/run-40637136248-ubuntu/timing.jsonl) and [raw memory pairs](evidence/run-40637136248-ubuntu/memory.jsonl)
- [Calibration](evidence/run-40637136248-ubuntu/calibration.json) and [completion receipt](evidence/run-40637136248-ubuntu/completion.json)

The workflow artifact also contains full build/test logs and the exact source
snapshots. The committed observations remain available after that artifact's
retention period expires.
