import Foundation
import Testing
@testable import IlliquidNativePlayback

@Suite("Native file version observation")
struct NativeFileContentVersionTests {
    @Test func renameReplacementAndSymlinkRetargetingUseTargetVersion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("movie.mkv")
        let renamed = root.appendingPathComponent("renamed.mkv")
        let link = root.appendingPathComponent("link.mkv")
        try Data([1, 2, 3]).write(to: file)
        let initial = try #require(NativeFileContentVersion.read(file))
        try FileManager.default.moveItem(at: file, to: renamed)
        #expect(NativeFileContentVersion.read(renamed) == initial)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: renamed)
        #expect(NativeFileContentVersion.read(link) == initial)
        try Data([4, 5, 6]).write(to: file, options: .atomic)
        let replacement = try #require(NativeFileContentVersion.read(file))
        #expect(replacement != initial)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(NativeFileContentVersion.read(link) == replacement)
        #expect(NativeFileContentVersion.verified(before: initial, after: replacement) == nil)
        #expect(NativeFileContentVersion.verified(before: initial, after: initial) == initial)
        #expect(NativeFileContentVersion.read(root) == nil)
        #expect(NativeFileContentVersion.read(root.appendingPathComponent("missing.mkv")) == nil)
    }
}
