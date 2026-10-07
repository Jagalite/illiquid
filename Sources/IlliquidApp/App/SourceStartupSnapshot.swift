import Foundation

/// Read once alongside history, before publishing the model. Decoding and
/// normalizing a large saved library must not run on the UI actor.
struct SourceStartupSnapshot: Sendable {
    static let foldersKey = "Illiquid.source-folders.v1"
    static let activeFolderKey = "Illiquid.active-source-folder.v1"
    static let tabsKey = "Illiquid.source-tabs.v1"
    static let activeTabKey = "Illiquid.active-source-tab.v1"

    let tabs: [SourceTab]
    let selectedID: String?

    static func load(defaults: UserDefaults) -> Self {
        let tabs: [SourceTab]
        if let restored = SourceTabStore.restore(from: defaults.data(forKey: tabsKey)) {
            tabs = restored
        } else {
            tabs = SourceTabs.migrating(SourceFolderLibrary.restore(
                from: defaults.array(forKey: foldersKey)))
        }
        let migratedSelection = defaults.string(forKey: activeFolderKey)
            .flatMap { SourceTabs.migratedTabID(forFolderID: $0) }
        return Self(tabs: tabs, selectedID: SourceTabs.resolvedSelection(
            defaults.string(forKey: activeTabKey) ?? migratedSelection, in: tabs))
    }
}
