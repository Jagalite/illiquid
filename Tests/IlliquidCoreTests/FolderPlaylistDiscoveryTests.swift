import Foundation
import Testing
@testable import IlliquidCore

@Suite("Folder playlist discovery")
struct FolderPlaylistDiscoveryTests {
    @Test("Discovery is shallow, filters unsupported files, and naturally sorts")
    func discoveryIsShallowFiltersUnsupportedFilesAndNaturallySorts() throws {
        let directory = try TemporaryDirectory()
        try directory.createFile("Episode 10.mkv")
        try directory.createFile("Episode 2.MP4")
        try directory.createFile("Episode 1.avi")
        try directory.createFile("notes.txt")
        try directory.createFile(".hidden.mp4")
        try directory.createFile("Season 2/Episode 3.mkv")

        let playlist = try FolderPlaylistDiscovery.discover(in: directory.url)

        #expect(
            playlist.items.map { $0.url.lastPathComponent }
                == ["Episode 1.avi", "Episode 2.MP4", "Episode 10.mkv"]
        )
    }

    @Test("Discovery attaches only related external subtitles")
    func discoveryAttachesOnlyRelatedExternalSubtitles() throws {
        let directory = try TemporaryDirectory()
        try directory.createFile("Show S01E02 1080p.mkv")
        try directory.createFile("Show S01E02.en.srt")
        try directory.createFile("Show S01E02.forced.ass")
        try directory.createFile("Different Movie.srt")

        let playlist = try FolderPlaylistDiscovery.discover(in: directory.url)

        #expect(playlist.count == 1)
        #expect(
            Set(playlist[0].externalSubtitleURLs.map(\.lastPathComponent))
                == Set(["Show S01E02.en.srt", "Show S01E02.forced.ass"])
        )
    }

    @Test("Discovery preserves title words when attaching external subtitles")
    func discoveryPreservesTitleWordsWhenAttachingExternalSubtitles() throws {
        let directory = try TemporaryDirectory()
        try directory.createFile("The Last of.mkv")
        try directory.createFile("The Last of Us.1080p.mkv")
        try directory.createFile("The Last of.srt")
        try directory.createFile("The Last of Us.en.srt")
        let playlist = try FolderPlaylistDiscovery.discover(in: directory.url)
        let matches = Dictionary(uniqueKeysWithValues: playlist.items.map {
            ($0.url.lastPathComponent, $0.externalSubtitleURLs.map(\.lastPathComponent))
        })
        #expect(matches == [
            "The Last of.mkv": ["The Last of.srt"],
            "The Last of Us.1080p.mkv": ["The Last of Us.en.srt"],
        ])
    }

    @Test("Discovery rejects a file URL as a folder")
    func discoveryRejectsAFileURLAsFolder() throws {
        let directory = try TemporaryDirectory()
        let fileURL = try directory.createFile("Movie.mkv")

        #expect(throws: FolderPlaylistDiscoveryError.self) {
            try FolderPlaylistDiscovery.discover(in: fileURL)
        }
    }
}
