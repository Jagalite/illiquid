# Thumbnail encoded-read allocation study

## Question and change

`NativeThumbnailDiskCache.readEncodedImage` checks a file's encoded length, then
reads it into owned `Data` in chunks of at most 64 KiB. Previously, the destination
started without reserved capacity. A multi-chunk read could therefore grow and
copy that destination repeatedly despite already knowing the initial file size.

The candidate starts with an empty `Data()` and calls `reserveCapacity` for the
**validated initial length** only when that length exceeds the existing 64 KiB
read chunk. Files that fit in one chunk keep the original destination behavior.
Both paths start with zero contents. The 16 MiB admission limit, chunk size, extra-byte growth check,
read-error handling, and independently owned image backing remain unchanged.
The hypothesis is lower allocation traffic for multi-chunk reads, without
changing returned bytes or rejection decisions.

An exploratory candidate reserved capacity for every accepted size. Its Linux
smoke run increased held allocator bytes for the 41,904-byte JPEG control, so
that candidate was rejected. The final candidate limits reservation to files
that require multiple chunks; the single-chunk fixtures explicitly check this
refinement. Results for unconditional reservation must remain separate from
measurements of the final candidate.

The baseline is commit `4abf4b44f13386ccd04f1ce4ad0e756255ca4d14`. The runner
compiles the complete reader function from that revision and from the working
tree into separate modules. It records full-source and extracted-source hashes
so results can be tied to the implementation actually measured.

## Reproduce

From the repository root, with Python 3 and a Swift toolchain available:

```sh
python3 Benchmarks/ThumbnailReadAllocation/run.py \
  --output /tmp/illiquid-thumbnail-read-allocation \
  --pairs 8
```

Use a fresh output directory and an even pair count of at least two for balanced
AB/BA execution order. An alternate compiler can be selected with
`--swiftc /absolute/path/to/swiftc`. The pinned baseline must be available in
local Git history. Follow the repository's build-coordination instructions and
submit this command through Kyoto when that queue is available.

The runner performs exact-byte verification before measurement, uses separate
baseline and candidate processes, and records paired execution order. Timing
uses an uninstrumented binary. Linux allocation counting uses a separate
interposed allocator run; those timings must not be substituted for the
uninstrumented measurements.

## Workloads and evidence

The byte fixtures cover an empty file, a 4 KiB file, lengths immediately below,
at, and above 64 KiB, and larger lengths through the 16 MiB boundary and its
one-byte rejection case. They contain deterministic bytes and exercise the
reader independently of ImageIO. They are **not JPEG-decoding benchmarks**.

Two bundled JPEGs contain deterministic RGB noise at 320 × 180 and 640 × 360,
encoded at quality 82. Their sizes are 41,904 and 162,337 bytes: one fits in a
single read chunk and the other spans several. `Fixtures/provenance.json` records
their generation method and hashes. These are valid image-format controls, not
recordings of typical user media. The larger deterministic files are stress
cases; do not describe a 16 MiB boundary result as a typical thumbnail saving.
Preallocation is not assumed to improve a single-chunk read.

The output includes source/toolchain receipts, the fixture manifest, command
logs, raw observations, and computed summaries. Inspect the raw paired results
alongside the summary; retain controls, regressions, and outlying samples.
Preflight checks verify complete returned bytes and lengths, including expected
rejection, rather than relying only on a sampled byte or checksum.

## Metric boundaries

- **Allocation requests** count successful `malloc`, `calloc`, and `realloc`
  calls observed process-wide by the Linux/glibc meter during the read loop.
  Other allocation families and failed requests are not counted.
- **Requested allocation bytes** sum the requested sizes of those calls. This
  is cumulative allocation traffic: repeated allocations or reallocations can
  count the same logical payload more than once. It is not retained memory.
- **Live allocator bytes**, where available, are allocator-wide observations
  before the read, while its result is held, and after release. Their deltas are
  affected by the runtime and allocator; they are not exact `Data` object sizes.
- **Current resident memory** is a process measurement at those checkpoints.
  It is not peak RSS, and freed allocator storage need not immediately leave RSS.
- **Elapsed time** covers the extracted file reader on the recorded fixture and
  host. Warm filesystem-cache results do not establish cold-disk latency.

The reader's FileHandle/Foundation work remains inside the component measurement.
ImageIO decoding, retained `CGImage` storage, cache eviction, actor scheduling,
native playback, whole-player memory, visible smoothness, and energy are outside
its scope. Linux allocator observations do not establish Darwin allocation
behavior. Native qualification is reported separately from portable measurements.

## File-change tradeoff and lifetime validation

If a file initially exceeds 64 KiB and shrinks after the size probe, reserving
its earlier length can retain more spare capacity than its eventual contents
need. That reservation is bounded by the validated 16 MiB limit. A file that
grows may require another allocation; the existing bounded read and extra-byte
rejection remain necessary. Static fixtures do not constitute a
concurrent-file-mutation experiment.

The image must continue to own its encoded backing after source promotion or
deletion. `ThumbnailImageLifetimeTests` independently checks the size boundary,
oversized-alias fallback/accounting, and exact decoded pixels after an
autorelease pool drains, a file is renamed, and the promoted file is removed.
Those native tests qualify image ownership and integration; the extracted reader
benchmark alone cannot establish them.

Final measurements and the executed native-test status belong in the retained
results and PR report. This methodology document does not assert an unmeasured
memory or timing improvement.
