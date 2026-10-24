import Foundation
import Testing
@testable import IlliquidApp

@Suite("Source sidebar sort defaults")
struct SourcesSidebarPreferencesTests {
    @Test func freshPreferencesSortByNewestDateInsteadOfName() {
        withDefaults { defaults in
            SourcesSidebarPreferences.initializeSortPreferences(defaults: defaults)
            let older = entry("A.mkv", created: 100)
            let newer = entry("Z.mkv", created: 200)
            #expect(SourceTreeSorting.sorted(
                [older, newer], using: configuration(defaults)
            ) == [newer, older])
            #expect(configuration(defaults).name == .off)
            #expect(configuration(defaults).type == .off)
        }
    }

    @Test func partialNamePreferenceRetainsItsOriginalEffectiveOrder() {
        withDefaults { defaults in
            defaults.set("descending", forKey: SourcesSidebarPreferences.nameSortKey)
            SourcesSidebarPreferences.initializeSortPreferences(defaults: defaults)
            let newer = entry("A.mkv", created: 200)
            let older = entry("Z.mkv", created: 100)
            #expect(SourceTreeSorting.sorted(
                [newer, older], using: configuration(defaults)
            ) == [older, newer])
            #expect(configuration(defaults).dateCreated == .off)
        }
    }

    @Test func explicitOffAndPartialTypePreferencesAreRetained() {
        withDefaults { defaults in
            defaults.set("off", forKey: SourcesSidebarPreferences.dateCreatedSortKey)
            defaults.set("descending", forKey: SourcesSidebarPreferences.typeSortKey)
            SourcesSidebarPreferences.initializeSortPreferences(defaults: defaults)
            #expect(configuration(defaults) == SourceTreeSortConfiguration(
                name: .ascending, dateCreated: .off, type: .descending
            ))
        }
    }

    @Test func initializationDoesNotOverrideLaterSelections() {
        withDefaults { defaults in
            SourcesSidebarPreferences.initializeSortPreferences(defaults: defaults)
            defaults.set("ascending", forKey: SourcesSidebarPreferences.nameSortKey)
            defaults.set("off", forKey: SourcesSidebarPreferences.dateCreatedSortKey)
            SourcesSidebarPreferences.initializeSortPreferences(defaults: defaults)
            #expect(configuration(defaults) == SourceTreeSortConfiguration(
                name: .ascending, dateCreated: .off, type: .off
            ))
        }
    }

    private func configuration(_ defaults: UserDefaults) -> SourceTreeSortConfiguration {
        SourceTreeSortConfiguration(
            name: .resolve(defaults.string(forKey: SourcesSidebarPreferences.nameSortKey)!),
            dateCreated: .resolve(defaults.string(forKey: SourcesSidebarPreferences.dateCreatedSortKey)!),
            type: .resolve(defaults.string(forKey: SourcesSidebarPreferences.typeSortKey)!)
        )
    }

    private func entry(_ name: String, created: TimeInterval) -> SourceTreeEntry {
        SourceTreeEntry(
            url: URL(fileURLWithPath: "/media/\(name)"), kind: .media,
            dateAdded: nil, creationDate: Date(timeIntervalSince1970: created)
        )
    }

    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let name = "SourcesSidebarPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        body(defaults)
    }
}
