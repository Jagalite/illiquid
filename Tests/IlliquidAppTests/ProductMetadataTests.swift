import Foundation
import IlliquidCore
import Testing

@Suite("Illiquid product metadata")
struct ProductMetadataTests {
    @Test("Info plist is the product metadata source of truth")
    func infoPlistDefinesProductIdentityAndVersion() throws {
        let metadata = try productMetadata()

        #expect(metadata["CFBundleName"] as? String == "Illiquid")
        #expect(metadata["CFBundleDisplayName"] as? String == "Illiquid")
        #expect(metadata["CFBundleExecutable"] as? String == "Illiquid")
        #expect(metadata["CFBundleIdentifier"] as? String == "io.github.jagalite.illiquid")
        #expect(metadata["CFBundleShortVersionString"] as? String == "0.1.3")
        #expect(metadata["CFBundleVersion"] as? String == "5")
        #expect(metadata["LSMinimumSystemVersion"] as? String == "26.0")
        #expect(metadata["NSHighResolutionCapable"] as? Bool == true)
        #expect(metadata["SUEnableAutomaticChecks"] as? Bool == true)
        #expect(metadata["SUAllowsAutomaticUpdates"] as? Bool == false)
        #expect(metadata["SURequireSignedFeed"] as? Bool == true)
        #expect(metadata["SUVerifyUpdateBeforeExtraction"] as? Bool == true)
        #expect(metadata["IlliquidBuildArchitectures"] as? [String] == ["arm64"])
        #expect((metadata["NSHumanReadableCopyright"] as? String)?.isEmpty == false)
    }

    @Test("Finder associations match every production scanner video extension")
    func documentTypesMatchProductionVideoExtensions() throws {
        let metadata = try productMetadata()
        let documentTypes = try #require(
            metadata["CFBundleDocumentTypes"] as? [[String: Any]]
        )
        let viewer = try #require(documentTypes.first)

        #expect(viewer["CFBundleTypeRole"] as? String == "Viewer")
        #expect(viewer["LSHandlerRank"] as? String == "Alternate")
        #expect(Set(viewer["CFBundleTypeExtensions"] as? [String] ?? [])
            == MediaFileSupport.videoFileExtensions)
        #expect((viewer["LSItemContentTypes"] as? [String])?.isEmpty == false)
        let imported = try #require(metadata["UTImportedTypeDeclarations"] as? [[String: Any]])
        #expect(imported.contains { $0["UTTypeIdentifier"] as? String == "io.github.jagalite.illiquid.video-container" })
        #expect((viewer["LSItemContentTypes"] as? [String])?.contains("io.github.jagalite.illiquid.video-container") == true)
    }

    private func productMetadata() throws -> [String: Any] {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(
            contentsOf: repositoryRoot.appendingPathComponent("Resources/Info.plist")
        )
        return try #require(
            PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any]
        )
    }
}
