# Local media explorer

The Sources sidebar has a **Media** view, selected in its view/visibility popover (or source visibility settings). Existing tabs keep their selected view; the default remains Tree. Media view recursively indexes supported video files on the existing source-preparation executor, reads local metadata on that executor, then builds rows on the browser actor. Tree and Files Only retain their existing lightweight filename behavior.

## Recognition and organization

| Naming evidence | Media view behavior |
| --- | --- |
| `Movie Title (2020).mkv`, `Movie.Title.2020.1080p.mkv` | Movie title and year under Movies |
| `Show (2020)/Season 01/S01E02 - Title.mkv` | Show, season, episode, and episode title |
| `Show.S01E02.Title.1080p.mkv`, `Show - 1x02 - Title.mkv` | Explicit episode markers; numeric episode order |
| `Show - S02E18-E19.mkv` | One file labelled as an episode range |
| `Season 00` / `Specials` with `S00E01` | Specials within the show |
| `Show - 2024-02-29.mkv`, `Show - 29.02.2024.mkv` | Valid calendar dates, ordered by date |
| `{imdb-tt123456}`, `{tmdb-123456}`, `{tvdb-123456}` | Locally supplied IDs available to search |
| `{edition-Final Cut}`, `part2`, `2160p` | Edition, split-part, and encode details retained in the secondary label |
| `-trailer`, `-deleted`, other Plex extra suffixes or extra folders | Extras separated from main videos |
| Unnumbered home videos, ambiguous names, absolute anime numbering | Original name under Other Videos |

Each playable row retains its original URL, identity, progress, visibility rules, play action, and Reveal in Finder action. Alternate encodes and editions remain separate files. Episode ranges and split parts are labels, not synthesized playback segments or concatenation. Movies, extras, and unknown files retain the selected file sort; episodes use numeric/date order, retaining file sort for alternate encodes of the same episode.

Search matches recognized titles, show/season labels, raw filenames, relative context paths, and supplied catalog IDs. Visibility and search run before section construction, so hidden or nonmatching files leave no empty group headings. Counts represent files, including alternate encodes. Search changes reuse parsed rows and compiled visibility evaluations. Scans are cancellable and source changes use the existing filesystem invalidation path.

## Local metadata

Media view also reads UTF-8 sidecars without opening the video stream:

- **`.plexmatch`**: series title/show, year, season, TVDB/TMDB/IMDb IDs, supported provider GUIDs, and explicit `ep`/`episode` filename mappings. Specials and same-season episode ranges are supported. The series file can map descendants; lower files map their own directory. Generic hints accumulate from outer to inner folders; explicit per-file episode mappings override general season hints.
- **`tvshow.nfo`**: series title, release year, and supported `uniqueid` fields inherited within the opened source.
- **`movie.nfo`**: folder-level movie identity for non-episode/non-extra files without series hints.
- **`<video-basename>.nfo`**: movie or episode metadata for that file. This takes precedence over folder hints. Episode `<title>` becomes the episode label; `<showtitle>` identifies its series. Episode air years and episode IDs are not reused as series release years or IDs.

For example, `.plexmatch` containing `title: The Show`, `season: 2`, and `ep: 3: opaque.mkv` identifies `opaque.mkv` as S02E03 without renaming it. An adjacent episode NFO can supply its readable episode title. The secondary label identifies NFO / `.plexmatch` provenance; original filenames remain searchable.

Metadata is read for both folder sources and explicitly added videos. Each scan owns a cache, including missing files, so shared show metadata is read once. Metadata writes, creates, removals, and renames invalidate the scan through the existing debounced filesystem monitor. Individual-file tabs watch their containing directories too. Sidecar data stays in immutable row snapshots; search and scrolling never read metadata files.

Reads stop at the opened source boundary (the containing folder for an individually added video). Regular, non-symlink sidecars only: at most 128 KiB per file, 16 MiB total data and 50,000 cached paths per scan, with a 64-directory ancestor bound. XML rejects DTD/entity declarations and limits nesting/text. Missing, malformed, unsupported, or over-budget metadata falls back to available filename evidence. Cancelled scans cannot publish partial replacements.

Supported NFO identification fields are `title`, `showtitle`, `year`, `season`, `episode`, and supported provider `uniqueid` elements under `movie`, `tvshow`, or `episodedetails`. This is not complete Plex/Kodi metadata compatibility: `.plexmatch` pattern directives, NFO URL-only scraper instructions, season NFO, multiple XML episode roots, remote artwork, plot/cast, and alternate encoding formats are not interpreted.

Sources: [Plex match hints](https://support.plex.tv/articles/plexmatch/), [Kodi movie NFO](https://kodi.wiki/view/NFO_files/Movies), [Kodi episode NFO](https://kodi.wiki/view/NFO_files/Episodes).

## Scope and limits

Recognition combines filename evidence with explicitly supplied local metadata; it is not an online verified catalog match. No network request, poster download, embedded media probe, rename, move, or deletion is performed. The name and metadata parsers are pure Foundation components in SuperplayrCore; filesystem work and SwiftUI state stay with their existing owners. Current player video extensions determine inclusion; subtitles and artwork are not playable library entries.

This does not implement a Plex server connection, online title correction, absolute-to-season anime mapping, collection metadata, or changed autoplay queues. Existing folder playlist behavior continues to determine next/previous playback. These need separate product decisions and stronger metadata than filename inference.

Conventions were checked against Plex's primary documentation:

- [Movie naming, editions, and split files](https://support.plex.tv/articles/naming-and-organizing-your-movie-media-files/)
- [TV naming, dates, specials, and episode ranges](https://support.plex.tv/articles/naming-and-organizing-your-tv-show-files/)
- [Local movie extras](https://support.plex.tv/articles/local-files-for-trailers-and-extras/)

## Validation

`MediaNameRecognitionTests` exercises explicit naming conventions, Unicode titles, date validation, extras precedence, and conservative fallbacks. `SourceMediaOrganizationTests` verifies file preservation, episode ordering, search caching, hidden ancestor rules, preview, and mode persistence. Existing source-browser tests cover the shared projection and scanning paths.

2026-09-05 validation: the complete release suite passed **762 tests in 104 suites**, with `SUPERPLAYR_NATIVE_REQUIRE_FIXTURES=1` and the generated native fixture directory enabled. `SuperplayrArchitectureCheck` and `git diff --check` passed. The synthetic 10,000-file release projection took 0.581 seconds; a subsequent cached search took 0.073 seconds on the development machine. These timings cover in-memory naming/projection/search, not disk traversal or rendered scrolling. The app was packaged for manual use; the player UI was not launched for visual verification.

Build: `./Scripts/build-platinum-app.sh --adhoc --output dist/media-explorer`.
Launch: `open dist/media-explorer/Platinum.app`.

Local-metadata follow-up validation (2026-09-05): **773 tests in 105 suites passed** in release with required native fixtures. Added sidecar parser/reader tests cover precedence, mapped ranges and specials, Unicode/CDATA, invalid XML and entity declarations, size limits, caching, cancellation, symlink refusal, source boundaries, and refresh after edits. Explorer tests cover corrected-title/ID search, explicit-file sources, overlapping source entries, and sidecar content invalidation. A 10,000-file / 5,000-directory watch-root derivation took 0.083 seconds; this measures lexical deduplication, not operating-system watcher setup. The sidebar's view expressions were separated to keep SwiftUI compilation tractable, with lifecycle cleanup preserved.

Packaged launch follow-up: startup initializer fix and live launch verification (reference omitted from this source export). The original static package audit did not exercise SwiftUI's delegate construction; a real launch exposed and verified the fix for that startup path. The rebuilt app remains at the same launch path.
