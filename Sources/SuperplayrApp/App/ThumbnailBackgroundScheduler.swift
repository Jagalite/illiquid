import Foundation
import Observation
import SuperplayrCore
import SuperplayrPlayer

@MainActor @Observable
final class ThumbnailBackgroundScheduler {
    static let preferencesKey = "Illiquid.thumbnail-preferences.v1"
    var preferences: ThumbnailPreferences {
        didSet {
            defaults.set(try? JSONEncoder().encode(preferences.bounded), forKey: Self.preferencesKey)
            let settings = preferences.bounded
            Task { [player] in await player.configureThumbnailCache(settings) }
            reschedule()
        }
    }
    private(set) var status = "Background generation is off."
    private(set) var cacheUsage: ThumbnailCacheUsage?
    @ObservationIgnored private var memoryPressureSource: DispatchSourceMemoryPressure?
    @ObservationIgnored private var isUnderMemoryPressure = false
    @ObservationIgnored private let player: PlaybackController
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let readDuration: @MainActor (URL) async -> Double?
    @ObservationIgnored private let generate: @MainActor (URL, Double) async -> Bool
    @ObservationIgnored private let releaseResources: @MainActor () async -> Void
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var deadline: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var powerObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var windowVisible = false
    @ObservationIgnored private var idle = false
    @ObservationIgnored private var current: URL?
    @ObservationIgnored private var folder: URL?
    @ObservationIgnored private var visible = Set<URL>()
    @ObservationIgnored private var discovered: [URL] = []
    @ObservationIgnored private var recent: [URL: Date] = [:]
    @ObservationIgnored private var focus: [URL: Double] = [:]

    init(player: PlaybackController, defaults: UserDefaults = .standard,
         readDuration: (@MainActor (URL) async -> Double?)? = nil,
         generate: (@MainActor (URL, Double) async -> Bool)? = nil,
         releaseResources: (@MainActor () async -> Void)? = nil) {
        self.readDuration = readDuration ?? { await player.thumbnailDuration(for: $0) }
        self.generate = generate ?? { await player.prewarmThumbnail(for: $0, at: $1) }
        self.releaseResources = releaseResources ?? { await player.releaseIdleThumbnailResources() }
        self.player = player
        self.defaults = defaults
        preferences = defaults.data(forKey: Self.preferencesKey)
            .flatMap { try? JSONDecoder().decode(ThumbnailPreferences.self, from: $0) }?.bounded
            ?? ThumbnailPreferences()
        let settings = preferences
        Task { await player.configureThumbnailCache(settings) }
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        pressure.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, let event = self.memoryPressureSource?.data else { return }
                await self.handleMemoryPressure(constrained: event.contains(.warning) || event.contains(.critical),
                                                critical: event.contains(.critical))
            }
        }
        memoryPressureSource = pressure
        pressure.resume()
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
            powerObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.reschedule() }
            })
        }
    }

    func updatePlayback(current: URL?, idle: Bool, windowVisible: Bool) {
        let changed = self.current != current || self.idle != idle || self.windowVisible != windowVisible
        if let current, self.current != current { recordUse(current, position: nil) }
        self.current = current
        self.idle = idle
        self.windowVisible = windowVisible
        if changed { reschedule() }
    }

    func navigate(folder: URL?, discovered: [URL], validPaths: Set<String>? = nil) {
        // Policy never initiates a filesystem walk. Bound UI-to-scheduler metadata too.
        let entries = Array(discovered.prefix(2048))
        let retainedVisible: Set<URL>
        if visible.isEmpty { retainedVisible = [] }
        else if let validPaths { retainedVisible = visible.filter { validPaths.contains($0.path) } }
        else { retainedVisible = visible.intersection(discovered.lazy.map(\.standardizedFileURL)) }
        guard self.discovered != entries || self.folder != folder?.standardizedFileURL
                || visible != retainedVisible else { return }
        visible = retainedVisible
        self.discovered = entries
        self.folder = folder?.standardizedFileURL
        reschedule()
    }

    func setVisible(_ url: URL, visible isVisible: Bool) {
        let url = url.standardizedFileURL
        let changed = isVisible ? visible.insert(url).inserted : visible.remove(url) != nil
        if changed { reschedule() }
    }

    func interaction(_ url: URL, position: Double) {
        recordUse(url, position: position)
        reschedule()
    }

    private func recordUse(_ url: URL, position: Double?) {
        let url = url.standardizedFileURL
        recent[url] = Date()
        if let position, position.isFinite { focus[url] = max(0, position) }
        if recent.count > 128, let oldest = recent.min(by: { $0.value < $1.value })?.key {
            recent.removeValue(forKey: oldest)
            focus.removeValue(forKey: oldest)
        }
    }

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        deadline?.cancel()
        deadline = nil
    }

    func shutdown() {
        stopped = true
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
        for observer in powerObservers { NotificationCenter.default.removeObserver(observer) }
        powerObservers.removeAll()
        cancel()
    }

    func clearCache() async {
        cancel()
        let cleared = await player.clearThumbnailCache()
        status = cleared ? "Thumbnail cache cleared." : "Some disk thumbnails could not be removed."
        await refreshCacheUsage()
    }

    func refreshCacheUsage() async {
        let usage = await player.thumbnailCacheUsage()
        guard !Task.isCancelled, !stopped else { return }
        cacheUsage = usage
    }

    func handleMemoryPressure(constrained: Bool, critical: Bool) async {
        guard !stopped else { return }
        isUnderMemoryPressure = constrained
        reschedule()
        if constrained { await player.handleThumbnailMemoryPressure(critical: critical) }
        await refreshCacheUsage()
    }

    private func reschedule() {
        cancel()
        let settings = preferences.bounded
        guard !stopped, settings.generatesInBackground else {
            status = "Background generation is off."
            return
        }
        guard idle, windowVisible || settings.generatesWithWindowClosed else {
            status = "Waiting for paused or stopped playback."
            return
        }
        guard !isUnderMemoryPressure else {
            status = "Background generation is paused while memory is limited."
            return
        }
        guard !ProcessInfo.processInfo.isLowPowerModeEnabled,
              ProcessInfo.processInfo.thermalState != .serious,
              ProcessInfo.processInfo.thermalState != .critical else {
            status = "Background generation is paused to conserve energy."
            return
        }
        let id = generation
        status = "Waiting for activity to settle…"
        task = Task(priority: .utility) { [weak self] in
            do { try await Task.sleep(for: .seconds(settings.idleSeconds)) } catch { return }
            guard let self, !Task.isCancelled, id == generation else { return }
            deadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(settings.workSeconds)) } catch { return }
                guard let self, generation == id else { return }
                task?.cancel()
                status = "Background work budget reached."
            }
            await runPass(settings: settings, id: id)
            if generation == id {
                deadline?.cancel(); deadline = nil; task = nil
            }
            // A cancelled pass still owns cleanup. Release only idle resources,
            // so late cleanup cannot cancel a newer foreground/background request.
            await releaseResources()
        }
    }

    private func runPass(settings: ThumbnailPreferences, id: UUID) async {
        let playlist = player.viewStore.playlist.map(\.url)
        let anchor = current.flatMap { playlist.firstIndex(of: $0) }
        let neighbors = anchor.map { index in
            Array(playlist[max(0, index - 4)..<min(playlist.count, index + 5)])
        } ?? []
        var urls = current.map { [$0] } ?? []
        urls += visible.sorted { $0.path < $1.path } + discovered + neighbors + recent.keys.sorted { $0.path < $1.path }
        var distances: [URL: Int] = [:]
        if let anchor {
            for index in max(0, anchor - 4)..<min(playlist.count, anchor + 5) {
                distances[playlist[index]] = abs(index - anchor)
            }
        }
        let candidates = urls.map { url in
            ThumbnailPolicy.Candidate(url: url, lastUsed: recent[url], isVisible: visible.contains(url),
                neighborDistance: distances[url])
        }
        let source = current, location = folder, now = Date()
        let ranked = await Task.detached(priority: .utility) {
            ThumbnailPolicy.ranked(candidates, current: source, folder: location, now: now, preferences: settings)
        }.value
        guard canContinue(id) else { return }
        var plans: [(URL, [Double])] = []
        var completed = 0
        // First image for each likely video precedes deeper coverage of any video.
        for url in ranked {
            guard canContinue(id) else { return }
            let progress = player.playbackProgress(for: url)
            let duration: Double?
            if let known = progress?.duration, known > 0 { duration = known }
            else { duration = await readDuration(url) }
            guard canContinue(id) else { return }
            guard let duration else { continue }
            let samples = ThumbnailPolicy.samples(duration: duration,
                focus: focus[url] ?? progress?.position ?? 0, count: settings.samplesPerVideo)
            guard let first = samples.first else { continue }
            if await generate(url, first) {
                completed += 1
                plans.append((url, Array(samples.dropFirst())))
            }
        }
        for request in ThumbnailPolicy.refinementOrder(plans.map { $0.1 }) {
            guard canContinue(id) else { return }
            if await generate(plans[request.video].0, request.position) { completed += 1 }
        }
        guard canContinue(id) else { return }
        status = "Prepared \(completed) previews across \(plans.count) videos."
    }

    private func canContinue(_ id: UUID) -> Bool {
        !Task.isCancelled && !stopped && !isUnderMemoryPressure && generation == id && idle
            && !ProcessInfo.processInfo.isLowPowerModeEnabled
            && ProcessInfo.processInfo.thermalState != .serious
            && ProcessInfo.processInfo.thermalState != .critical
    }
}
