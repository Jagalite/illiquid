# Catalog-ID storage during metadata merging

Media metadata is reused across the files in a folder. The old merge path
reconstructed the catalog-ID array even when one input had no IDs, creating
separate buffers that could have shared Swift's copy-on-write storage.

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
Common workloads use one or three catalog IDs; larger arrays are explicit stress
cases. Controls cover empty arrays and nonempty arrays requiring provider
replacement. Retained heap is measured while the full result cohort remains
alive, with equivalent baseline and candidate outputs.

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

Results will be recorded after the paired experiment and correctness checks
complete.
