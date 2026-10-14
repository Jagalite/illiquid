import Foundation
import Testing
@testable import IlliquidCore

@Suite("Caption navigation")
struct CaptionNavigationTests {
    @Test func assMarkupCommasAndDrawingModesDoNotBecomeSearchNoise() {
        #expect(CaptionText.fromASSPacket(#"0,0,Default,,0,0,0,,{\i1}Hello, world!\Nこんにちは"#) == "Hello, world!\nこんにちは")
        #expect(CaptionText.plainASS(#"{\p1}m 0 0 l 10 10{\p0}Visible\htext"#) == "Visible text")
        #expect(CaptionText.plainASS(#"{\pos(1,2)}Keep me"#) == "Keep me")
        #expect(CaptionText.fromASSPacket("malformed") == "")
    }

    @Test func externalASSHonorsFormatAndDeduplicatesTextEvents() throws {
        let data = Data("""
        [Script Info]
        Title: Test
        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:12.00,0:00:14.00,Default,,0,0,0,,Café, déjà vu!
        Comment: 0,0:00:13.00,0:00:14.00,Default,,0,0,0,,not visible
        Dialogue: 0,0:00:10.00,0:00:11.00,Default,,0,0,0,,Earlier
        Dialogue: 0,0:00:12.00,0:00:14.00,Default,,0,0,0,,Café, déjà vu!
        """.utf8)
        let index = CaptionText.parseASSDocument(data)
        #expect(index.isComplete)
        #expect(index.cues.count == 2)
        #expect(index.cues.map(\.id) == [0, 1])
        #expect(index.cues.map(\.start) == [10, 12])
        #expect(index.search("CAFE").map(\.text) == ["Café, déjà vu!"])
        #expect(index.search("", limit: 1).count == 1)
        #expect(index.search("not visible").isEmpty)
        #expect(index.search("cafe", limit: 0).isEmpty)
    }

    @Test func navigationInvertsTheNativeSubtitleDelay() throws {
        let cue = try #require(CaptionCue(id: 44, start: 10, end: 12, text: "Caption"))
        let index = CaptionIndex(cues: [cue])
        #expect(index.target(for: 0, subtitleDelay: 1.5) == 8.5)
        #expect(index.target(for: 0, subtitleDelay: -1.5) == 11.5)
        #expect(index.target(for: 0, subtitleDelay: 20) == 0)
        #expect(index.target(for: 0, subtitleDelay: 0, duration: 8) == 8)
        #expect(index.target(for: 44, subtitleDelay: 0) == nil)
        #expect(index.target(for: 0, subtitleDelay: .nan) == nil)
        #expect(index.previousCue(at: 9, subtitleDelay: 1.5)?.id == 0)
    }

    @Test func sentenceReplayHasBoundedDeterministicGrouping() throws {
        let cues = [(1.0, 2.0, "This is"), (2.1, 4.0, "one sentence."),
                    (4.2, 5.0, "Another sentence!"), (10.0, 11.0, "Later")].enumerated().compactMap {
            CaptionCue(id: $0.offset, start: $0.element.0, end: $0.element.1, text: $0.element.2)
        }
        let index = CaptionIndex(cues: cues)
        #expect(index.previousSentence(at: 3, subtitleDelay: 0)?.start == 1)
        #expect(index.previousSentence(at: 4.25, subtitleDelay: 0)?.start == 1)
        #expect(index.previousSentence(at: 4.6, subtitleDelay: 0)?.start == 4.2)
        #expect(index.previousSentence(at: 10.5, subtitleDelay: 0)?.start == 10)
        #expect(index.previousCue(at: .infinity, subtitleDelay: 0) == nil)
    }

    @Test func malformedAndOversizedInputsStayBounded() {
        #expect(CaptionCue(id: 0, start: .nan, end: 1, text: "Bad") == nil)
        #expect(CaptionCue(id: 0, start: 2, end: 1, text: "Bad") == nil)
        #expect(CaptionCue(id: 0, start: 0, end: 1, text: String(repeating: "a", count: 65_537)) == nil)
        let data = Data("[Events]\nFormat: Start, End, Text\nDialogue: 0:99:00,0:99:01,Bad".utf8)
        #expect(!CaptionText.parseASSDocument(data).isComplete)
        let cues = (0...CaptionIndex.maximumCues).compactMap {
            CaptionCue(id: $0, start: Double($0), end: Double($0 + 1), text: "Cue \($0)")
        }
        let index = CaptionIndex(cues: cues)
        #expect(index.cues.count == CaptionIndex.maximumCues)
        #expect(!index.isComplete)
    }
    @Test func cancellationAndMalformedLargeOverridesDoNotLeakPartialResults() {
        let cues = (0..<1_000).compactMap {
            CaptionCue(id: $0, start: Double($0), end: Double($0 + 1), text: "needle \($0)")
        }
        #expect(CaptionIndex(cues: cues).search("needle", isCancelled: { true }).isEmpty)
        let braces = String(repeating: "{", count: 65_000)
        #expect(CaptionText.plainASS(braces) == braces)
        let document = "[Events]\nFormat: Start, End, Text\nDialogue: 0:00:00,0:00:01,"
            + String(repeating: "x", count: 65_537)
        let index = CaptionText.parseASSDocument(Data(document.utf8))
        #expect(index.cues.isEmpty)
        #expect(!index.isComplete)
    }

}
