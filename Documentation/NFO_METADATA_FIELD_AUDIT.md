# NFO metadata field-selection audit

Date: 2026-10-17. Baseline: `8c3cc3d4008d5d1b8d436bcf2d51d891382b6548`.

## Scope and confirmed defect

This investigation targets NFO XML field selection, not subtitle matching,
filename recognition, catalog-ID merging, or the existing playback-pipeline PR.
The only production file changed is `NFOMetadataHints.swift`. The catalog-ID
branch changes `MediaMetadataHints.swift` and `MediaSidecarTests.swift`; neither
is modified here. The new regressions use a separate test file.

The parser retained text for every direct child of the XML root, including
`plot`, `outline`, and other fields it never consumes. Its 4096-character scalar
limit therefore invalidated an otherwise useful NFO when an ignored field was
long. It returned no metadata, rather than simply ignoring the unsupported
field. This was reproduced with the actual baseline Swift implementation:

| Payload | Baseline | Candidate |
| --- | --- | --- |
| 4096-character plot, valid title/year | Metadata retained | Metadata retained |
| 4097-character plot, valid title/year | Entire NFO rejected | Metadata retained |
| 65,536-character plot, valid title/year | Entire NFO rejected | Metadata retained |
| 4097-character title | Rejected | Rejected |

The failure can lose a movie's title/year or a series/episode's explicit identity.
The filesystem regressions demonstrate both per-file NFO loading and show/episode
NFO precedence; no real media corpus or visible app session was used.

## Fix and invariants

A depth- and content-aware `capturesText` predicate permits text accumulation
only for fields consumed by `didEndElement`. CDATA uses the same predicate before
conversion to a Swift string. `showtitle` is only consumed for episodes, and
`year` is not consumed for episodes, matching the existing interpretation.

The 128 KiB document limit, 4096-character consumed-field limit, 32-level nesting
limit, XML well-formedness checks, and DOCTYPE/ENTITY rejection are unchanged.
Unknown fields still cannot establish an identity, and nested title/year elements
inside ignored metadata cannot override direct identification fields. No parser
public API, catalog-ID policy, file-open flags, read loop, cache budget, or
cancellation behavior changes.

## Verification and reproduction

The dedicated harness compiles the five real media-library sources and the
existing eight sidecar tests plus twelve new test functions. Parameterized
cases cover four ignored fields across all three supported NFO roots. Additional
coverage includes CDATA, text split across callbacks, XML entities, Unicode,
exact/over-limit document sizes, nesting, malformed XML, a deterministic 64-case
ignored-field corpus, real temporary files, caching, and metadata precedence.

Run from a checkout with Swift 6.1 or newer; no playback SDK or network dependency
resolution is needed:

```sh
python3 Scripts/test-nfo-metadata-regressions.py --output /tmp/nfo-debug
python3 Scripts/test-nfo-metadata-regressions.py --configuration release --output /tmp/nfo-release
```

To verify that the new tests detect the original defect, substitute only the
baseline parser while keeping the same tests and remaining sources:

```sh
git show 8c3cc3d4008d5d1b8d436bcf2d51d891382b6548:Sources/IlliquidCore/MediaLibrary/NFOMetadataHints.swift > /tmp/nfo-baseline.swift
python3 Scripts/test-nfo-metadata-regressions.py --nfo-source /tmp/nfo-baseline.swift --output /tmp/nfo-baseline
# Expected: nonzero test exit, with failures in the new field-selection suite.
```

Local results on Linux x86_64, Swift 6.2.1:

- Baseline: the existing eight test functions passed; the new suite produced
  106 failed expectations. These include parameterized and corpus assertions,
  not 106 separate test functions.
- Candidate: all 20 test functions passed in both debug and release builds.
- A separate candidate run passed all twelve new functions without adapting
  any test fixture source.
- Source copies were checked against the GitHub blob hashes before modification.
  The harness records original/compiled SHA-256 values, toolchain, configuration,
  and every adaptation alongside the full test log.

On macOS, all five sources and both test files are compiled byte-for-byte. Linux
requires `FoundationXML` and `Glibc` import adaptations in disposable copies.
The older tests also construct their root URLs before creating the directories;
Linux Foundation retains a missing directory hint, making the root URL unequal
to the same-path parent directory URL. The initial unadapted run consequently
failed before reading files. The harness adds explicit directory hints to those
legacy **test fixtures only** on Linux. The new tests specify their directory
hints in their original source. No URL-comparison production change is included.

The dedicated macOS workflow runs both configurations without these adaptations.
Its actual run status must be checked separately; Linux results are not a macOS
app build, complete native suite, or visible playback qualification.

## Earlier short-read hypothesis: not retained

The earlier suggestion that one `FileHandle.read(upToCount:)` necessarily means
one underlying read was not supported by the available implementation. The
[Swift Foundation source](https://github.com/swiftlang/swift-corelibs-foundation/blob/main/Sources/Foundation/FileHandle.swift)
calls a loop until the requested size or EOF. In a separate Linux experiment,
a test interposer limited reads of one regular fixture file to seven bytes:
`FileHandle` returned all 65,536 bytes, byte-identical, across 9,364 read calls
(including EOF). No read-loop patch is justified by that result.

This negative control covers Linux Foundation, not a macOS network filesystem or
interrupted-I/O behavior. Such platform-specific scenarios remain unqualified.
