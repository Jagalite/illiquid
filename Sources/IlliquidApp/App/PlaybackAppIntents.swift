import AppIntents
import Foundation
import IlliquidCore

/// A media/time bookmark carried between Shortcuts actions. The identifier is
/// versioned, bounded and validated by IlliquidCore; it is not a live-session
/// command token, a network address, or a grant of filesystem access.
struct PlaybackReferenceEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Playback Reference")
    static let defaultQuery = PlaybackReferenceEntityQuery()

    let id: String
    let reference: PlaybackReference

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(reference.url.lastPathComponent)",
            subtitle: "\(reference.position.formatted(.number.precision(.fractionLength(2)))) seconds")
    }

    init(reference: PlaybackReference) throws {
        self.reference = reference
        id = try reference.encodedIdentifier()
    }
}

struct PlaybackReferenceEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [PlaybackReferenceEntity] {
        guard identifiers.count <= PlaybackAutomationPolicy.maximumFiles else {
            throw PlaybackAutomationError.invalidReference
        }
        return try identifiers.map {
            try PlaybackReferenceEntity(reference: PlaybackReference.decodeIdentifier($0))
        }
    }

    // Do not enumerate playback history or access files as a side effect of
    // showing a Shortcuts parameter picker. References come from explicit actions.
    func suggestedEntities() async throws -> [PlaybackReferenceEntity] { [] }
}

struct OpenMediaAtTimeIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Media at Timestamp"
    static let description = IntentDescription("Open a local media file at an explicit time, overriding its saved resume position. Returns after the source and seek are acknowledged, not just queued.")
    static let openAppWhenRun = true

    @Parameter(title: "File") var file: IntentFile
    @Parameter(title: "Timestamp (seconds)", default: 0) var seconds: Double
    @Parameter(title: "Start Paused", default: false) var paused: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$file) at \(\.$seconds) seconds") { \.$paused }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<PlaybackReferenceEntity> {
        let urls = try PlaybackIntentFiles.localURLs([file])
        let access = PlaybackIntentFiles.beginAccess(urls)
        defer { PlaybackIntentFiles.endAccess(access) }
        guard let model = await AppModel.loadShared() else { throw PlaybackAutomationError.noPlayback }
        model.reopenPlayerWindow()
        let reference = try await model.player.openMedia(at: urls[0], position: seconds, paused: paused)
        return .result(value: try PlaybackReferenceEntity(reference: reference))
    }
}

struct EnqueueOrderedMediaIntent: AppIntent {
    static let title: LocalizedStringResource = "Enqueue Media in Order"
    static let description = IntentDescription("Append accessible local media files in the supplied order, ignoring duplicates. Validates every file before changing the queue. An empty player opens the first new file paused. Returns the number added.")
    static let openAppWhenRun = true

    @Parameter(title: "Files") var files: [IntentFile]

    static var parameterSummary: some ParameterSummary { Summary("Enqueue \(\.$files) in order") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> {
        let urls = try PlaybackIntentFiles.localURLs(files)
        let access = PlaybackIntentFiles.beginAccess(urls)
        defer { PlaybackIntentFiles.endAccess(access) }
        guard let model = await AppModel.loadShared() else { throw PlaybackAutomationError.noPlayback }
        model.reopenPlayerWindow()
        return .result(value: try await model.player.enqueueOrderedMedia(urls).count)
    }
}

struct GetPlaybackReferenceIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Playback Reference"
    static let description = IntentDescription("Return the settled local media file and playback time as a reusable reference. Unfinished opens and seeks do not return a guessed position. References contain the local path and do not grant access to the file.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<PlaybackReferenceEntity> {
        guard let model = await AppModel.loadShared() else { throw PlaybackAutomationError.noPlayback }
        return .result(value: try PlaybackReferenceEntity(reference: model.player.currentPlaybackReference()))
    }
}

struct OpenPlaybackReferenceIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Playback Reference"
    static let description = IntentDescription("Reopen a returned playback reference after verifying that the local file still matches. A moved or replaced file requires an explicit new open or Locate; the reference does not grant filesystem access.")
    static let openAppWhenRun = true

    @Parameter(title: "Playback Reference") var playbackReference: PlaybackReferenceEntity
    @Parameter(title: "Start Paused", default: false) var paused: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$playbackReference)") { \.$paused }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<PlaybackReferenceEntity> {
        guard let model = await AppModel.loadShared() else { throw PlaybackAutomationError.noPlayback }
        model.reopenPlayerWindow()
        let reference = try await model.player.openPlaybackReference(playbackReference.reference, paused: paused)
        return .result(value: try PlaybackReferenceEntity(reference: reference))
    }
}

struct IlliquidAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: GetPlaybackReferenceIntent(),
            phrases: ["Get my playback reference in \(.applicationName)"],
            shortTitle: "Playback Reference", systemImageName: "bookmark")
    }
}

/// The current app is not sandboxed. These actions accept existing on-disk
/// files; they do not materialize provider data or copy large videos into a
/// temporary import directory. A returned reference is never an access bookmark.
/// Scoped URLs, when supplied, are balanced around the acknowledged action.
enum PlaybackIntentFiles {
    static func localURLs(_ files: [IntentFile]) throws -> [URL] {
        guard !files.isEmpty, files.count <= PlaybackAutomationPolicy.maximumFiles else {
            throw PlaybackAutomationError.invalidFile
        }
        return try PlaybackAutomationPolicy.orderedLocalURLs(files.map { file in
            guard let url = file.fileURL else { throw PlaybackAutomationError.invalidFile }
            return url
        })
    }

    static func beginAccess(_ urls: [URL]) -> [URL] {
        urls.filter { $0.startAccessingSecurityScopedResource() }
    }

    static func endAccess(_ urls: [URL]) {
        for url in urls { url.stopAccessingSecurityScopedResource() }
    }
}
