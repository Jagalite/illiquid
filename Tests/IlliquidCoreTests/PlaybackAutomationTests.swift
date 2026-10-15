import Foundation
import Testing
@testable import IlliquidCore

@Suite("Playback automation contracts")
struct PlaybackAutomationTests {
    private var version: MediaContentVersion {
        .init(fileIdentifier: 17, byteCount: 123, modificationSeconds: 1,
              modificationNanoseconds: 2, creationSeconds: 3, creationNanoseconds: 4)
    }

    @Test func referenceRoundTripPreservesUnicodeAndTime() throws {
        let original = try PlaybackReference(url: URL(fileURLWithPath: "/Volumes/Media/日本語 film.mkv"),
            position: 123.456, contentVersion: version)
        #expect(try PlaybackReference.decodeIdentifier(original.encodedIdentifier()) == original)
        #expect(original.schemaVersion == 1)
    }

    @Test func referenceAndTimestampRejectMalformedInputs() throws {
        for time in [-1.0, .nan, .infinity, -.infinity, Double.greatestFiniteMagnitude] {
            #expect(throws: PlaybackAutomationError.self) {
                try PlaybackReference(url: URL(fileURLWithPath: "/a.mkv"), position: time, contentVersion: version)
            }
            #expect(throws: PlaybackAutomationError.self) { try PlaybackAutomationPolicy.validateTimestamp(time) }
        }
        for time in [0.0, 0.1, 1.0, 10_000.25] { try PlaybackAutomationPolicy.validateTimestamp(time) }
        #expect(throws: PlaybackAutomationError.self) {
            try PlaybackReference(url: URL(string: "https://example.com/a.mkv")!, position: 2, contentVersion: version)
        }
        for invalid in ["", "%%%", String(repeating: "A", count: 12_001)] {
            #expect(throws: PlaybackAutomationError.self) { try PlaybackReference.decodeIdentifier(invalid) }
        }
        let ref = try PlaybackReference(url: URL(fileURLWithPath: "/a.mkv"), position: 2, contentVersion: version)
        let data = try JSONEncoder().encode(ref)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["schemaVersion"] = 99
        let future = try JSONSerialization.data(withJSONObject: object).base64EncodedString()
        #expect(throws: PlaybackAutomationError.self) { try PlaybackReference.decodeIdentifier(future) }
    }

    @Test func orderedInputsDoNotUseFilenameOrDateOrdering() throws {
        let b = URL(fileURLWithPath: "/videos/z.mkv")
        let a = URL(fileURLWithPath: "/videos/a.mp4")
        let alias = URL(fileURLWithPath: "/videos/./z.mkv")
        #expect(try PlaybackAutomationPolicy.orderedLocalURLs([b, a, alias]) == [b, a])
        #expect(throws: PlaybackAutomationError.self) { try PlaybackAutomationPolicy.orderedLocalURLs([]) }
        #expect(throws: PlaybackAutomationError.self) {
            try PlaybackAutomationPolicy.orderedLocalURLs([b, URL(string: "https://example.com/a.mkv")!])
        }
        #expect(throws: PlaybackAutomationError.self) {
            try PlaybackAutomationPolicy.orderedLocalURLs(Array(repeating: b, count: 257))
        }
    }
    @Test func fileURLAuthoritiesAndFragmentsAreNotSilentlyReinterpretedAsLocalPaths() throws {
        for raw in ["file://server/movie.mkv", "file:///movie.mkv?x=1", "file:///movie.mkv#time=4", "file:///movie%00.mkv"] {
            let url = try #require(URL(string: raw))
            #expect(throws: PlaybackAutomationError.self) { try PlaybackAutomationPolicy.orderedLocalURLs([url]) }
            #expect(throws: PlaybackAutomationError.self) { try PlaybackReference(url: url, position: 0, contentVersion: version) }
        }
        #expect(PlaybackAutomationPolicy.isLocalFileURL(URL(fileURLWithPath: "/movie.mkv")))
        // A literal percent sign followed by 00 is an ordinary filename.
        #expect(PlaybackAutomationPolicy.isLocalFileURL(URL(string: "file:///movie%2500.mkv")!))
    }

}
