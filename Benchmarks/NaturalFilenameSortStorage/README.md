# Natural filename sort storage research

## Finding and runtime scope

Sorting cached integer indices reduces temporary allocation traffic while
preserving the existing natural filename ordering and complete original values.
On the measured Swift 6.3.2 / x86_64 Linux runtime, a 10,000-URL sort requests
**199,968 fewer bytes**, and the 10,000-item `FolderPlaylist` constructor requests
**559,968 fewer bytes**. These reductions repeat in every measured pattern and
all six pairs. This is an allocation-storage result, not a whole-player RAM or
frame-rate result. Timings are mixed; no general throughput improvement is claimed.

The common production path is `NaturalFilenameOrdering.sort([URL])`: folder
preparation, matched subtitles, item subtitle arrays, and dropped subtitles use
it. The wide-item overload is used by the public `FolderPlaylist` constructor.
Normal verified discovery already uses its `sortedItems:` initializer, so the
wide-item measurements describe the constructor and discovery fallback, not the
usual cost of opening every folder. No filesystem reads, rendering, decoding,
or physical Mac playback were measured here.

## Implementation and semantics

The old implementation caches `(Element, String)` records and sorts those whole
records. The new implementation caches filenames in one array, stable-sorts an
array of original integer indices, then gathers the original elements once.
The sort's merge buffers consequently contain integers instead of URLs or
playlist records plus names. Caches are scoped to one call.

Filename extraction still happens once per element. The localized natural
comparison and the literal **original full path** tie-break are unchanged.
Comparator-equal entries retain input order, consistent with Swift's
[stable-sort contract](https://forums.swift.org/t/accepted-se-0372-document-sorting-as-stable/60425).
No URL normalization or item reconstruction is added. Dates, exact URL spellings,
relative/base URLs, duplicates, and deliberately unsorted decoded subtitle arrays
survive intact. Empty, singleton, and pair fast paths remain unchanged.

The old records retain copy-on-write subtitle references; they do not deep-copy
subtitle payloads. This change reduces top-level working-buffer storage, without
claiming to eliminate copies of subtitle contents.

## Allocation results

Both revisions are built from complete production files. The baseline is
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`. The measured candidate sorter has SHA-256
`c09072130b113b90faa49b17ff95ce8983668734e69dddf6244572f5de80de62`, matching the
published source in `be02897e57f2675dfec9b73aba3271d9aa3a2913`.

| Operation | Items | Fewer requested bytes per operation | KiB |
| --- | ---: | ---: | ---: |
| URL sorting | 1,000 | 19,968 | 19.5 |
| URL sorting | 10,000 | 199,968 | 195.3 |
| Playlist constructor | 1,000 | 55,968 | 54.7 |
| Playlist constructor | 10,000 | 559,968 | 546.8 |

Every row applies to shuffled, sorted, reversed, repeated-name/path-tie, and
Unicode fixtures. The new representation makes **one additional allocation
request** for inputs entering the cached path, but requests fewer total bytes
in these workloads. The three-URL control requests eight more bytes; zero-, one-,
and two-element controls have unchanged allocation traffic. The eight-URL case
saves 32 bytes. All control results are retained.

The observed layouts are: `URL` 16 bytes, `FolderPlaylistItem` 40 bytes,
`String` 16 bytes, and `Int` 8 bytes. Original URL/name and item/name records have
32- and 56-byte strides respectively. The large allocation sizes agree with
this working-array accounting at 10,000 elements:

| Working arrays, excluding returned output | Baseline requests | Candidate requests | Reduction |
| --- | ---: | ---: | ---: |
| URL sort | 480,064 bytes | 280,096 bytes | 41.65% |
| Playlist item sort | 840,064 bytes | 280,096 bytes | 66.66% |

This accounting identifies array requests from the recorded size histogram and
element layouts; it is not an observed peak-live-memory measurement. Both
implementations still allocate the returned array. Foundation's localized
comparison accounts for much of the remaining traffic: across the 10,000-URL
patterns the **total** requested-byte reduction is approximately 0.14–3.59%,
not 41.65% of the operation's entire memory use.

The calibrated glibc probe counts successful requests on the calling thread
through malloc, calloc, realloc, memalign, aligned_alloc, and posix_memalign.
Realloc charges the full new requested size; frees are not subtracted. Internal
libc allocations and other unwrapped APIs are outside the counter. It measures
neither retained heap, allocator capacity, peak RSS, nor macOS footprint.
Timing executables do not load this probe.

## Timing results and follow-up

The complete six-pair study contains mixed results. This table retains every
10,000-element workload, including slower cases. Values are median milliseconds
per complete operation. Ratio-of-medians change and median paired change are
different statistics and can disagree when observations vary.

| Workload | Baseline ms | Candidate ms | Median ratio change | Median paired change |
| --- | ---: | ---: | ---: | ---: |
| urls / shuffled | 233.937 | 231.371 | -1.10% | -1.14% |
| urls / sorted | 14.987 | 14.806 | -1.21% | -1.17% |
| urls / reversed | 15.861 | 15.736 | -0.78% | +0.33% |
| urls / ties | 469.470 | 489.997 | +4.37% | -0.59% |
| urls / unicode | 296.349 | 286.180 | -3.43% | -1.32% |
| playlist / shuffled | 264.895 | 305.065 | +15.16% | +12.73% |
| playlist / sorted | 17.079 | 16.198 | -5.16% | -4.46% |
| playlist / reversed | 17.226 | 17.174 | -0.30% | +2.77% |
| playlist / ties | 513.388 | 527.042 | +2.66% | +1.17% |
| playlist / unicode | 317.432 | 283.838 | -10.58% | -8.24% |

The 10,000-item shuffled playlist's original median paired increase was 12.73%;
1,000-URL shuffled and tied-name cases increased about 6.6%. A targeted follow-up
therefore repeated exactly those three cases with twelve balanced fresh-process
pairs, longer measured loops, and process CPU time in addition to wall time.
The driver set one allowed CPU before launching children; this was not exclusive
hardware. It reused the exact already-built production libraries and changed
only the harness's CPU-time instrumentation and measurement configuration.

| Targeted case | Baseline CPU ms | Candidate CPU ms | Median paired CPU change |
| --- | ---: | ---: | ---: |
| playlist/shuffled/10000 | 240.737 | 222.319 | -5.45% |
| urls/shuffled/1000 | 24.146 | 23.469 | -2.51% |
| urls/ties/1000 | 50.031 | 50.182 | -0.07% |

The earlier slowdowns did not reproduce in this follow-up. Both datasets remain
available; the repeat does not prove the first results were noise or establish
universal nonregression. The repeatable benefit supporting the change is reduced
allocation traffic. Native latency, whole-player memory, and physical user-visible
performance remain separate qualification tasks.

## Correctness, evidence, and reproducibility

The full study passed **13 tests in two suites** in each of baseline release,
candidate debug, and candidate release. The same current tests run on both
implementations. The new test uses 257 decoded items with mixed/equal keys,
forward/reversed inputs, raw URLs, distinct dates, and unsorted subtitle metadata.
The independent harness additionally verifies **66 complete output cases per
variant**, including byte-sensitive URL representations.

Thirty measured cases cover both operations, five large-input patterns at
1,000/10,000 elements, and 0/1/2/3/8-element controls. Six AB/BA pairs in separate
fresh processes produce **720 observations**: 360 uninstrumented latency and
360 single-operation allocation observations. Fixtures, independent reference
sorting, full validation, and fingerprints are outside the measured window;
every timed result contributes to a checked observer. No outliers are removed
and no latency threshold is used. The targeted follow-up adds 72 timing
observations in a separate retained cohort.

An independent read-back audit verified every saved observation against its
command stdout, all pair identities/orders/fingerprints, all source/test/driver/
binary hashes, all 740 successful commands, and all summary calculations:
**22,870 checks passed**. The evidence preserves the actual executed runner;
its later `--current-support` addition changes PR integration mode, while the
frozen default research path remains unchanged.

Permanent evidence is in [`evidence/linux/`](evidence/linux/): readable summaries,
manifests, verification and audit receipts; compressed observations and command
inventory; a deterministic archive of complete logs and source/test/driver
snapshots; and the targeted follow-up cohort. Build products are excluded, but
their hashes and full compiler commands are retained.

```sh
python3 Benchmarks/NaturalFilenameSortStorage/run.py \
  --pairs 6 --sizes 1000,10000 --output /tmp/natural-filename-sort-study

# Small CI smoke with the same current support files in both variants.
python3 Benchmarks/NaturalFilenameSortStorage/run.py \
  --quick --pairs 2 --current-support --output /tmp/natural-filename-sort-smoke
```

Use a new output directory and Swift 6.1 or newer with bundled Swift Testing,
Python 3.9 or newer, and a C compiler on glibc Linux. `--swift` selects an explicit
toolchain. On macOS, correctness and latency run without the Linux allocation
meter. Per `AGENTS.md`, use Kyoto when available; the measured Linux host and
hosted CI runners have no Kyoto installation, and their builds are serialized.

Default research runs require the unchanged support files to match the pinned
baseline. `--current-support` instead pairs the frozen sorter with current
`FolderPlaylist` and `NormalizedFileURL` files shared identically by both
variants, and labels this hybrid baseline in its manifest. This lets ongoing PR
regression checks survive unrelated support-file changes without silently
changing the historical experiment.

The focused [Linux/macOS CI run](https://github.com/Jagalite/illiquid/actions/runs/40640472210)
is separate from this permanent local evidence. A queued native job is not native
qualification; consult the current run/PR status. The complete player graph,
physical Mac interaction, and end-to-end RAM/FPS were not qualified by this study.
