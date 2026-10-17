# NFO metadata scoping and malformed-document rejection

Research date: October 17, 2026. Source baseline: `8c3cc3d4008d5d1b8d436bcf2d51d891382b6548`.

## Scope

This investigation starts from `main`, not the playback-pipeline branch. It changes only `NFOMetadataHints` production logic. It does not change catalog-ID merging (separate PR #11), filename recognition, subtitle association, sidecar I/O, cache budgets, or playback. Visible NFO PRs and branches were checked again before publication; unpublished concurrent work cannot be ruled out.

## Finding 1: show totals become per-file episode identity

[Kodi's TV-show NFO specification](https://kodi.wiki/view/NFO_files/TV_shows) defines show-level `<season>` and `<episode>` as library counts. They are not the season/episode coordinates of each video. The parser previously assigned both fields for all supported roots, including `tvshow` and `movie`.

The resulting hints flowed through `MediaSidecarReader`, `MediaMetadataHints.overriding`, and `RecognizedMediaName.applying`. A show with five seasons and 62 episodes could therefore:

- Relabel different episodes as `S05E62`, changing their season sections.
- Erase a filename's multi-episode range or air date, including after a title-only episode NFO.
- Reclassify unrelated videos and movie filenames as episodes.
- Substitute five for Plex's implicit directory/default season, or overwrite an explicit ancestor Plex season when a child `tvshow.nfo` is read.

**Fix:** assign these two fields only under `episodedetails`. Show title, year, and catalog IDs still load. Count-only show/movie documents now supply no supported hints. Explicit episode-sidecar precedence and specials remain unchanged. This is Illiquid's existing explicit-override policy; it is not a claim to replicate all of Kodi's filename precedence rules.

The filesystem regression compares complete recognized records, display names, and section names before and after adding show totals. Nine paths cover numbered episodes, ranges, specials, both supported date orders, an otherwise opaque numbered filename, unrelated files, movies, and trailers. Other tests cover Plex fallback and explicit overrides.

## Finding 2: a reported XML error can still yield partial hints

On the tested Linux Swift 6.2.1 FoundationXML runtime, these malformed documents return `true` from `XMLParser.parse()` while setting `parserError` to `NSXMLParserErrorDomain` code 5:

```xml
<tvshow><title>Valid</title><season>5</season><episode>62</episode>
```

```xml
<tvshow><title>Valid</title></tvshow><episodedetails><episode>1</episode></episodedetails>
```

The original parser checked only the Boolean result and its own delegate flags. Because the title callback had already supplied a value, partially parsed metadata escaped. File-backed tests reproduce this for unfinished show, movie, and episode documents.

**Fix:** also require `parser.parserError == nil` before returning hints. This uses the documented [parser error mechanism](https://developer.apple.com/documentation/foundation/xmlparserdelegate/parser(_:parseerroroccurred:)). Apple's Foundation and [Linux corelibs Foundation](https://github.com/swiftlang/swift-corelibs-foundation) are distinct implementations: the Boolean/error inconsistency is confirmed locally on Linux, not yet on macOS. The native CI job tests the same rejection policy without Linux import adjustments.

Every proper byte prefix of three valid ASCII NFO documents must be rejected. Complete valid documents at the 4,096-character field limit and 128 KiB file limit still parse, as does a UTF-8 BOM/declaration with Unicode text. Existing rejection of DTDs/entities, excessive nesting, oversized input, and invalid numbers remains covered. Concatenated multi-root documents are rejected rather than partially interpreted; this change does not add legacy stacked multi-episode NFO support.

## Validation and reproducibility

The five production source snapshots were checked against their GitHub blob hashes before running them. The runner compiles those actual sources and the repository's tests in an isolated Swift package, without resolving the full macOS app graph. On Linux it only adds the FoundationXML import and substitutes Glibc for Darwin in temporary copies. It does not replace parsing, merging, recognition, or filesystem logic.

Existing sidecar test fixtures now explicitly construct directory URLs, including child directories. Without that correction, Linux URL equality prevented these fixtures from reaching the intended scan root. No production root-boundary behavior is changed.

Final suite, Swift 6.2.1 on Linux x86_64:

| Source/configuration | Result |
| --- | --- |
| Original source, current tests, debug | 28 tests; 10 test functions fail with 201 failed expectations |
| Candidate, debug | 28 tests in 3 suites pass |
| Candidate, optimized (`-c release`) | 28 tests in 3 suites pass |

The two existing suites pass against both source versions after the fixture correction. The new suite contains 14 test functions, including parameterized cases and loops. The numbers above are the Swift Testing runner's test-function totals, not a count of input cases. In an earlier 26-test ablation, scoping alone left five malformed-XML expectations failing; explicit parser-error rejection resolves that separate failure mode.

```sh
bash Scripts/test-nfo-metadata-regressions.sh
bash Scripts/test-nfo-metadata-regressions.sh -c release

# Requires the baseline commit in local Git history. Expected to fail:
ILLIQUID_NFO_SOURCE_REF=8c3cc3d4008d5d1b8d436bcf2d51d891382b6548 \
  bash Scripts/test-nfo-metadata-regressions.sh
```

The dedicated `NFO metadata regressions` workflow runs debug and optimized suites on the same macOS/Xcode selection as the existing restoration workflow. Adding that job is not evidence that it has passed: inspect the PR's actual run before merging. Full application/UI playback tests and visible library behavior on macOS remain separate qualification steps. No CPU, energy, memory, or playback-performance improvement is claimed.
