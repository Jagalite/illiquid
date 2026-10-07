import AppKit
import Combine
import Sparkle

/// Sparkle owns scheduling, download verification, consent, and installation.
@MainActor
final class AppUpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = AppUpdateController()
    static let prereleasesKey = "Illiquid.updates.includesPrereleases"

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var unavailableReason: String?
    @Published var includesPrereleases: Bool {
        didSet {
            defaults.set(includesPrereleases, forKey: Self.prereleasesKey)
            controller?.updater.resetUpdateCycleAfterShortDelay()
        }
    }

    private let defaults: UserDefaults
    private var controller: SPUStandardUpdaterController?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        includesPrereleases = defaults.bool(forKey: Self.prereleasesKey)
        super.init()
    }

    func start() {
        guard controller == nil else { return }
        guard Bundle.main.bundleURL.pathExtension == "app",
              ProcessInfo.processInfo.environment["ILLIQUID_ENABLE_BENCHMARK_OVERRIDES"] != "1" else {
            unavailableReason = "Update checks are available in the installed app."
            return
        }
        guard Self.hasValidConfiguration(Bundle.main.infoDictionary ?? [:]) else {
            unavailableReason = "Update checks aren’t configured for this build."
            return
        }
        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil
        )
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$canCheckForUpdates)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$automaticallyChecksForUpdates)
        do {
            try controller.updater.start()
        } catch {
            unavailableReason = "Update checks could not start: \(error.localizedDescription)"
        }
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        controller?.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        controller?.updater.automaticallyChecksForUpdates = enabled
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        Self.channels(includingPrereleases: includesPrereleases)
    }

    static func channels(includingPrereleases: Bool) -> Set<String> {
        includingPrereleases ? ["beta"] : []
    }

    static func hasValidConfiguration(_ info: [String: Any]) -> Bool {
        guard let feed = info["SUFeedURL"] as? String,
              let url = URL(string: feed), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil,
              let key = info["SUPublicEDKey"] as? String,
              Data(base64Encoded: key)?.count == 32 else { return false }
        return true
    }
}
