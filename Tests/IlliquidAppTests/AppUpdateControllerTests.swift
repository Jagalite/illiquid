import Foundation
import Testing
@testable import IlliquidApp

@Suite("App updates")
@MainActor
struct AppUpdateControllerTests {
    @Test func stableChannelIsDefaultAndPrereleasePreferencePersists() throws {
        let suite = "AppUpdateControllerTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let updates = AppUpdateController(defaults: defaults)
        #expect(!updates.includesPrereleases)
        #expect(AppUpdateController.channels(includingPrereleases: false).isEmpty)
        updates.includesPrereleases = true
        #expect(AppUpdateController(defaults: defaults).includesPrereleases)
        #expect(AppUpdateController.channels(includingPrereleases: true) == ["beta"])
        #expect(!updates.canCheckForUpdates) // Creating preferences never starts network work.
    }

    @Test func configurationRequiresHTTPSAndARealPublicKey() {
        var info: [String: Any] = ["SUFeedURL": "https://example.com/appcast.xml",
                                  "SUPublicEDKey": Data(repeating: 1, count: 32).base64EncodedString()]
        #expect(AppUpdateController.hasValidConfiguration(info))
        for url in ["http://example.com/appcast.xml", "file:///tmp/feed.xml", "https://user:password@example.com/feed.xml"] {
            info["SUFeedURL"] = url
            #expect(!AppUpdateController.hasValidConfiguration(info))
        }
        info["SUFeedURL"] = "https://example.com/appcast.xml"
        info["SUPublicEDKey"] = "placeholder"
        #expect(!AppUpdateController.hasValidConfiguration(info))
    }
}
