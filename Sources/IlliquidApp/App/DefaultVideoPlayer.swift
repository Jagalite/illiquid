import AppKit
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class DefaultVideoPlayer {
    static let shared = DefaultVideoPlayer()
    static let asksOnLaunchKey = "Illiquid.defaultVideoPlayer.asksOnLaunch"

    var asksOnLaunch: Bool {
        didSet { defaults.set(asksOnLaunch, forKey: Self.asksOnLaunchKey) }
    }
    private var evaluatedLaunchOffer = false

    private(set) var isChanging = false
    private(set) var result: String?
    let applicationURL: URL
    let extensions: [String]
    private let defaults: UserDefaults
    private let resolve: (String) -> UTType?
    private let currentApplication: (UTType) -> URL?
    private let setApplication: (URL, UTType) async throws -> Void

    init(
        applicationURL: URL = Bundle.main.bundleURL,
        extensions: [String] = DefaultVideoPlayer.declaredExtensions,
        defaults: UserDefaults = .standard,
        resolve: @escaping (String) -> UTType? = { UTType(filenameExtension: $0, conformingTo: .movie) },
        currentApplication: @escaping (UTType) -> URL? = {
            NSWorkspace.shared.urlForApplication(toOpen: $0)
        },
        setApplication: @escaping (URL, UTType) async throws -> Void = {
            try await NSWorkspace.shared.setDefaultApplication(at: $0, toOpen: $1)
        }
    ) {
        self.applicationURL = applicationURL
        self.extensions = extensions
        self.defaults = defaults
        self.asksOnLaunch = defaults.object(forKey: Self.asksOnLaunchKey) as? Bool ?? true
        self.resolve = { ext in
            guard let type = resolve(ext), type.conforms(to: .movie) else { return nil }
            return type
        }
        self.currentApplication = currentApplication
        self.setApplication = setApplication
    }

    static var declaredExtensions: [String] {
        let declarations = Bundle.main.object(forInfoDictionaryKey: "CFBundleDocumentTypes") as? [[String: Any]] ?? []
        return Array(Set(declarations.flatMap { $0["CFBundleTypeExtensions"] as? [String] ?? [] })).sorted()
    }

    var isInstalled: Bool {
        let path = applicationURL.resolvingSymlinksInPath().path
        let directories = ["/Applications/", NSHomeDirectory() + "/Applications/"]
        return applicationURL.pathExtension == "app" && directories.contains { path.hasPrefix($0) }
    }

    var shouldOffer: Bool {
        isInstalled && !extensions.isEmpty && asksOnLaunch
            && !extensions.allSatisfy { ext in
                guard let type = resolve(ext) else { return false }
                return isCurrentApplication(type)
            }
    }

    // A reopened player window is still the same app launch.
    func takeLaunchOffer() -> Bool {
        guard !evaluatedLaunchOffer else { return false }
        evaluatedLaunchOffer = true
        return shouldOffer
    }

    private func isCurrentApplication(_ type: UTType) -> Bool {
        currentApplication(type)?.resolvingSymlinksInPath().standardizedFileURL
            == applicationURL.resolvingSymlinksInPath().standardizedFileURL
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        let error = error as NSError
        return (error.domain == NSCocoaErrorDomain && error.code == NSUserCancelledError)
            || (error.domain == NSOSStatusErrorDomain && error.code == Int(userCanceledErr))
    }

    func makeDefault() async {
        guard !isChanging else { return }
        guard isInstalled else {
            result = "Move Illiquid to Applications and open it there before making it your default player."
            return
        }
        guard !extensions.isEmpty else {
            result = "This copy of Illiquid does not declare any supported video formats."
            return
        }
        isChanging = true
        result = nil
        defer { isChanging = false }
        var attempted = Set<String>()
        var failures: [String] = []
        for ext in extensions {
            guard let type = resolve(ext) else { continue }
            guard attempted.insert(type.identifier).inserted, !isCurrentApplication(type) else { continue }
            do {
                try await setApplication(applicationURL, type)
            } catch {
                if Self.isCancellation(error) {
                    result = "Default-player changes cancelled. Any changes already completed remain in place. You can try again from Settings → Behavior."
                    return
                }
                failures.append("\(ext.uppercased()): \(error.localizedDescription)")
            }
        }
        // Resolve again after changes: several extensions can share one content type.
        let remaining = extensions.filter { ext in
            guard let type = resolve(ext) else { return true }
            return !isCurrentApplication(type)
        }
        if remaining.isEmpty {
            result = "Illiquid is now the default player for all supported video formats."
        } else {
            result = "Could not make Illiquid the default for: \(remaining.map { $0.uppercased() }.joined(separator: ", ")). You can try again or use Finder → Get Info → Open with → Illiquid → Change All."
            if !failures.isEmpty { result = (result ?? "") + "\n\n" + failures.joined(separator: "\n") }
        }
    }
}
