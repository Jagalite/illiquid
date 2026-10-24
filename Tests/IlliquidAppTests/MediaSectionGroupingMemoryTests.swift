import Foundation
import IlliquidCore
import Testing
@testable import IlliquidApp

@Suite("Media section grouping storage regressions")
struct MediaSectionGroupingMemoryTests {
    @Test func searchedVariantRowsKeepTheirFieldsMultiplicityAndFirstHeader() async throws {
        let first = row("first", filename: "Cafe\u{301}.S01E10.mkv", label: "selected last episode")
        let variantA = row("variant-a", filename: "Café.S01E02.2160p.mkv", label: "selected high resolution")
        let variantB = row("variant-b", filename: "CAFÉ.S01E02.1080p.mkv", label: "selected low resolution")
        let earliest = row("earliest", filename: "Café.S01E01.mkv", label: "selected first episode")
        var unrecognized = row("unrecognized", filename: "home.mp4")
        unrecognized.recognizedMedia = nil
        let rows = [
            row("movie", filename: "Example (2020).mkv"), first, unrecognized, variantA,
            row("other-series", filename: "Another.S01E01.mkv"), variantB, variantA, earliest,
        ]
        var configuration = mediaConfiguration()
        configuration.showsHiddenItems = true
        configuration.manuallyHiddenPaths = [variantA.url.path]
        let result = try #require(await SourceBrowserFilter().project(
            rows: rows, configuration: configuration, roots: [], revealsRulePreview: false, query: "selected"
        ))

        var markedVariantA = variantA
        markedVariantA.visibility = SourceRowVisibility(matches: [.manual], isInherited: false)
        let members = [earliest, markedVariantA, variantB, markedVariantA, first]
        let title = try #require(first.recognizedMedia?.section)
        let header = SourceTreeDisplayRow(
            id: "media-section:" + title, folderID: "", url: first.url,
            displayName: title + " (5)", depth: 0, ancestorIDs: [], kind: .mediaSection
        )
        // Search leaves gaps in the source positions. Equal episode variants
        // retain their input order and duplicate rows keep their multiplicity.
        #expect(result.rows == [header] + members)
        #expect(result.rows[0].displayName.utf8.elementsEqual(header.displayName.utf8))
        #expect(result.thumbnailCandidates == members.map(\.url))
        #expect(result.mediaPaths == Set(members.map { $0.url.standardizedFileURL.path }))
        #expect(result.hiddenCount == 2)
    }

    @Test func mixedRecognitionAndRetainedProjectionSurviveSourceReplacement() async throws {
        var missingA = row("missing-a", filename: "first-home.mp4")
        missingA.recognizedMedia = nil
        let unknown = row("unknown", filename: "another-home.mp4")
        #expect(unknown.recognizedMedia?.kind == .unknown)
        var missingB = row("missing-b", filename: "last-home.mp4")
        missingB.recognizedMedia = nil
        let movie = row("movie", filename: "Movie (2020).mkv")
        let episode = row("episode", filename: "Show.S01E01.mkv")
        let filter = SourceBrowserFilter()
        let configuration = mediaConfiguration()
        let original = try #require(await filter.project(
            rows: [missingA, movie, unknown, episode, missingB], configuration: configuration,
            roots: [], revealsRulePreview: false, query: ""
        ))
        let originalRows = original.rows
        #expect(Array(original.rows.suffix(3)) == [missingA, unknown, missingB])
        #expect(original.rows.first { $0.id == "media-section:Other Videos" }?.url == missingA.url)

        let replaced = try #require(await filter.project(
            rows: [missingB, episode, unknown, missingA], configuration: configuration,
            roots: [], revealsRulePreview: false, query: ""
        ))
        #expect(Array(replaced.rows.suffix(3)) == [missingB, unknown, missingA])
        #expect(replaced.rows.first { $0.id == "media-section:Other Videos" }?.url == missingB.url)
        #expect(!replaced.rows.contains { $0.kind == .mediaSection && $0.displayName.hasPrefix("Movies") })
        // The UI may still hold the previous value when a new source snapshot
        // arrives. Its row values must remain independent of the next grouping.
        #expect(original.rows == originalRows)
        #expect(original.thumbnailCandidates == [movie, episode, missingA, unknown, missingB].map(\.url))
        #expect(await filter.visibilityBuildCount == 2)
    }

    @Test func cancelledMediaProjectionDoesNotReplaceTheCachedSourceRows() async throws {
        let filter = SourceBrowserFilter()
        let configuration = mediaConfiguration()
        let rows = [
            row("later", filename: "Show.S01E10.mkv"),
            row("earlier", filename: "show.S01E01.mkv"),
        ]
        let cached = try #require(await filter.project(
            rows: rows, configuration: configuration, roots: [], revealsRulePreview: false, query: ""
        ))
        let replacement = row("replacement", filename: "Replacement (2020).mkv")
        let cancelled = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return await filter.project(
                rows: [replacement], configuration: configuration,
                roots: [], revealsRulePreview: false, query: "Replacement"
            )
        }
        #expect(await cancelled.value == nil)
        let restored = try #require(await filter.project(
            rows: rows, configuration: configuration, roots: [], revealsRulePreview: false, query: " \n"
        ))
        #expect(restored.rows == cached.rows)
        #expect(restored.thumbnailCandidates == cached.thumbnailCandidates)
        #expect(restored.mediaPaths == cached.mediaPaths)
        #expect(await filter.visibilityBuildCount == 1)
    }

    private func mediaConfiguration() -> SourceVisibilityConfiguration {
        var configuration = SourceVisibilityConfiguration.default
        configuration.viewMode = .media
        return configuration
    }

    private func row(_ id: String, filename: String, label: String? = nil) -> SourceTreeDisplayRow {
        let url = URL(fileURLWithPath: "/tmp/media-section-storage/" + id + ".mkv")
        var recognized = MediaNameRecognition.recognize(relativePath: filename)
        recognized.metadataSources = ["NFO", ".plexmatch"]
        return SourceTreeDisplayRow(
            id: id, folderID: "folder-" + id, url: url, displayName: label ?? id,
            contextLabel: "Original context " + id, recognizedMedia: recognized,
            visibilityPath: url.path, depth: 3, ancestorIDs: ["root", "parent-" + id],
            kind: .media(dateAdded: Date(timeIntervalSince1970: 123_456)),
            containsSupportedMedia: true
        )
    }
}
