# Recursive media scan performance

## Problem and change

`SourceRecursiveMediaLoader.read` discovers media for recursive source-browser
views. Previously it resolved filesystem identity for every enumerated entry
before examining the original entry's resource values. Directories, nonregular
entries, and unrelated files therefore paid for path resolution even when they
could not contribute a media row.

The change reads the resource values requested by the directory enumerator
first. It preserves the existing directory/package traversal rules and
original-entry regular-file check. A known nonsymlink with an unsupported media
extension can then be discarded before filesystem identity resolution.

Accepted candidates still resolve filesystem identity. Known links and unknown
link status still use the resolved URL's extension. For a known nonsymlink,
the earlier successful extension check is reused only when the original and
resolved URLs have exactly equal `absoluteString` UTF-8 bytes. This avoids
classifying ordinary supported files twice without relying on Swift String's
Unicode equivalence for identity.

The root-resolution path, explicit-file admission, resolved visibility paths,
deduplication, date fallback order, and optional sidecar recognition retain their
existing behavior. Cancellation is checked after resource-value access and
after resolving accepted candidates.

## Measurement

The [benchmark](../Benchmarks/RecursiveMediaScan/README.md) compares the current
production scanner with the exact scanner declaration retained from
`7f9ba073394b77a908e0589447c6edc8d10b832c`. Both variants compile the same current
supporting production declarations. The driver is a separate executable target;
the scanner is not copied into a simplified benchmark implementation.

Each workload uses eight balanced AB/BA process pairs. Every process performs
one untimed warmup followed by three measured complete scans. Fixture creation,
receipt serialization, and comparison occur outside the timed calls. Both
monotonic wall time and process CPU time are recorded. Process averages are the
independent observations; individual scans within a process are not counted as
independent pairs.

The fixtures cover supported ASCII media, supported Unicode media, a tree with
90% unrelated files, many directories, symlink and nonregular-entry controls,
overlapping roots with explicit files, and optional sidecar metadata. All
fixtures remain unchanged while measuring. These are warm filesystem scans;
the harness does not flush the operating system's filesystem caches.

Every process compares the complete ordered result of every measured scan with
its warmup. Baseline and candidate receipts must also match exactly, including
URL bytes, visibility paths, date bit patterns, row kinds, and recognized media
fields. Each workload retains a complete receipt for both variants, raw timing
samples, source and binary hashes, environment details, and command/test logs.

## Correctness coverage

The dedicated regression suite covers nested media, uppercase and Unicode
names, hidden entries, package descendants, folders with media-like names,
explicit unsupported and nonexistent files, overlapping roots, duplicate
entries, preserved dates, NFO recognition, root aliases, entry symlinks, and
cancellation throughout a single-root scan with explicit files and with/without
metadata. Existing media-organization tests run alongside it. Both old and new
scanners run the same tests in debug and release configurations.

The recursive scanner continues to classify the *original entry's* regular-file
resource key. It does not adopt the different target-classification behavior of
shallow playlist discovery. Tests use the platform's actual resource values for
entry-link admission. Unknown symbolic-link metadata is handled conservatively
in code; the fixtures do not force an unavailable resource key.

## Interpretation and limits

The optimization reduces work in the recursive discovery component. It does
not establish a change in playback frame rate, decoding cost, SwiftUI layout,
or complete user-visible folder-open latency. Network filesystems, cold caches,
very large real libraries, and resource contention need separate measurements.

As before, a scan is not an atomic filesystem snapshot. Moving an early type
or extension check ahead of resolution can change what is observed if an entry
is replaced during enumeration. Equivalence receipts cover stable fixture
contents, not concurrent filesystem replacement.

An initial extension-prefilter implementation classified accepted files again
unconditionally and showed a supported-only regression. The exact-URL reuse
condition addresses that unnecessary duplicate work; supported ASCII and
Unicode workloads remain explicit controls in the final study.

## Existing benchmark integration

Three older source-browser studies also stage the recursive scanner as shared
support for their semantic tests. Their historical strict modes correctly
reject unrelated support changes. Their PR workflows now select an explicit
current-support mode: the historical focal projection/filter implementation
remains the baseline, while both variants compile identical current supporting
sources, including this scanner. Source origins and hashes identify that
integration context. Historical defaults, frozen baselines, and previously
retained measurements remain unchanged.
