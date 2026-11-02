import Foundation
import Testing
import IlliquidCore

@Suite("Media file extension classification")
struct MediaFileSupportTests {
    @Test(arguments: MediaFileSupport.videoFileExtensions.sorted())
    func supportedVideoExtensionsKeepTheirCaseVariants(_ fileExtension: String) {
        for spelling in [fileExtension, fileExtension.uppercased(), alternatingCase(fileExtension)] {
            let url = URL(fileURLWithPath: "/Media/Series/Video.\(spelling)")
            #expect(MediaFileSupport.isSupportedMediaFile(url))
            #expect(!MediaFileSupport.isSupportedSubtitleFile(url))
        }
    }

    @Test(arguments: MediaFileSupport.subtitleFileExtensions.sorted())
    func supportedSubtitleExtensionsKeepTheirCaseVariants(_ fileExtension: String) {
        for spelling in [fileExtension, fileExtension.uppercased(), alternatingCase(fileExtension)] {
            let url = URL(fileURLWithPath: "/Media/Series/Video.en.\(spelling)")
            #expect(MediaFileSupport.isSupportedSubtitleFile(url))
            #expect(!MediaFileSupport.isSupportedMediaFile(url))
        }
    }

    @Test(arguments: ["", "txt", "TXT", "sup", "sUb", "mp4backup", "mkv ", "mp-4", "123", "ｍｋｖ", "mkv\u{0301}", "m\u{001f}kv", "m\u{007f}kv"])
    func unsupportedExtensionsStayUnsupported(_ fileExtension: String) {
        let url = URL(fileURLWithPath: "/Media/Video.\(fileExtension)")
        #expect(!MediaFileSupport.isSupportedMediaFile(url))
        #expect(!MediaFileSupport.isSupportedSubtitleFile(url))
    }

    @Test func nonASCIIExtensionUsesTheExistingLocaleLowercase() {
        // Kelvin sign lowercases to ASCII k. A blanket ASCII-only rejection
        // would change this existing supported-media result.
        let kelvin = URL(fileURLWithPath: "/Media/Video.m\u{212a}v")
        #expect(MediaFileSupport.isSupportedMediaFile(kelvin))
        #expect(!MediaFileSupport.isSupportedSubtitleFile(kelvin))

        for spelling in ["m\u{212a}v", "M\u{212a}V", "ſrt", "sİrt", "sırt", "ＭＫＶ", "mkv\u{0301}", "🎬"] {
            let url = URL(fileURLWithPath: "/Media/Video.\(spelling)")
            let normalized = url.pathExtension.lowercased(with: Locale(identifier: "en_US_POSIX"))
            #expect(MediaFileSupport.isSupportedMediaFile(url) == MediaFileSupport.videoFileExtensions.contains(normalized))
            #expect(MediaFileSupport.isSupportedSubtitleFile(url) == MediaFileSupport.subtitleFileExtensions.contains(normalized))
        }
    }

    @Test(arguments: [
        ("/Media/.hidden.mp4", true, false),
        ("/Media/.mp4", false, false),
        ("/Media/Movie.part.one.mkv", true, false),
        ("/Media/Movie.mkv.", false, false),
        ("/Media/Movie", false, false),
        ("/Media/字幕.en.ass", false, true),
        ("/Media/日本語 Café 🎬.mp4", true, false),
        ("/Media/日本語 Cafe\u{0301} 🎬.mp4", true, false),
    ])
    func filenameAndUnicodePathBehaviorIsUnchanged(_ example: (String, Bool, Bool)) {
        let (path, media, subtitle) = example
        let url = URL(fileURLWithPath: path)
        #expect(MediaFileSupport.isSupportedMediaFile(url) == media)
        #expect(MediaFileSupport.isSupportedSubtitleFile(url) == subtitle)
    }

    @Test(arguments: [
        "file:///Media/Movie.m%6Bv",
        "file:///Media/Movie%2Emp4",
        "file:///Media/Movie.mp4?download=yes",
        "file:///Media/Movie.mp4#frame",
        "file://server/Media/Movie.mp4",
    ])
    func URLExtractionAndFileAuthorityKeepFoundationSemantics(_ text: String) throws {
        let url = try #require(URL(string: text))
        #expect(url.isFileURL)
        #expect(MediaFileSupport.isSupportedMediaFile(url))
        #expect(!MediaFileSupport.isSupportedSubtitleFile(url))
    }

    @Test func relativeAndBridgedFileURLsRemainSupported() throws {
        let base = URL(fileURLWithPath: "/Media/", isDirectory: true)
        let relative = try #require(URL(string: "Episode.MKV", relativeTo: base))
        let bridged = NSURL(fileURLWithPath: "/Media/Episode.mkv") as URL
        #expect(MediaFileSupport.isSupportedMediaFile(relative))
        #expect(MediaFileSupport.isSupportedMediaFile(bridged))
    }

    @Test(arguments: ["https://example.com/Movie.mp4", "http://example.com/Movie.MKV", "smb://server/Subtitle.srt", "ftp://example.com/Subtitle.ass"])
    func nonFileSchemesRemainExcluded(_ text: String) throws {
        let url = try #require(URL(string: text))
        #expect(!MediaFileSupport.isSupportedMediaFile(url))
        #expect(!MediaFileSupport.isSupportedSubtitleFile(url))
    }

    @Test func classificationDoesNotAddFilesystemOrDirectoryChecks() {
        // Existence and item kind are the responsibility of discovery callers.
        let url = URL(fileURLWithPath: "/nonexistent/Directory.mkv", isDirectory: true)
        #expect(MediaFileSupport.isSupportedMediaFile(url))
    }

    @Test func longExtensionsRemainUnsupported() {
        for spelling in [String(repeating: "a", count: 4096),
                         String(repeating: "a", count: 4095) + "A",
                         String(repeating: "é", count: 4096)] {
            let url = URL(fileURLWithPath: "/Media/Video.\(spelling)")
            #expect(!MediaFileSupport.isSupportedMediaFile(url))
            #expect(!MediaFileSupport.isSupportedSubtitleFile(url))
        }
    }

    private func alternatingCase(_ value: String) -> String {
        value.enumerated().map { index, character in
            index.isMultiple(of: 2) ? String(character).uppercased() : String(character)
        }.joined()
    }
}
