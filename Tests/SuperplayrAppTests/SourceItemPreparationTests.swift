import Foundation
import Testing
import SuperplayrCore
@testable import SuperplayrApp

@Suite("Source item preparation")
struct SourceItemPreparationTests {
    @Test func classifiesAndDeduplicatesCanonicalAliasesOffTheUIActor() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let video = root.appendingPathComponent("video.mkv")
        let alias = root.appendingPathComponent("alias.mkv")
        let text = root.appendingPathComponent("text.txt")
        try Data().write(to: video)
        try Data().write(to: text)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: video)
        let items = try await SourcePreparationExecutor.shared.perform { check in
            #expect(!Thread.isMainThread)
            return try SourceItemPreparation.prepare([alias, video, root, text], kind: nil, checkCancellation: check)
        }
        #expect(items.count == 2)
        #expect(items.contains(SourceTabItem(kind: .file, url: video)))
        #expect(items.contains(SourceTabItem(kind: .folder, url: root)))
        #expect(throws: CancellationError.self) {
            try SourceItemPreparation.prepare([root], kind: nil) { throw CancellationError() }
        }
    }
    @Test func simultaneousDirectoryExpansionDoesNotReportBusyForHealthyLocalFolders() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("video.mkv"))
        await withTaskGroup(of: SourceDirectoryListing.self) { group in
            for _ in 0..<12 { group.addTask { await SourceDirectoryLoader.load(root) } }
            for await listing in group {
                #expect(listing.errorMessage == nil)
                #expect(listing.entries.count == 1)
            }
        }
    }

}
