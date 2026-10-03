import Foundation

public struct PlaybackSessionRecord: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public var source: MediaSource
    public var collectionFolder: URL?
    public var playlistItems: [FolderPlaylistItem]
    public var playlistIndex: Int?
    public var unshuffledPlaylistIDs: [FolderPlaylistItem.ID]?
    public var position: TimeInterval
    public var wasPaused: Bool
    public var updatedAt: Date

    public init(
        source: MediaSource,
        collectionFolder: URL? = nil,
        playlistItems: [FolderPlaylistItem] = [],
        playlistIndex: Int? = nil,
        position: TimeInterval,
        wasPaused: Bool,
        unshuffledPlaylistIDs: [FolderPlaylistItem.ID]? = nil,
        updatedAt: Date = Date()
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.source = source
        self.collectionFolder = collectionFolder
        self.playlistItems = PlaylistMutation.deduplicated(playlistItems)
        self.playlistIndex = playlistIndex
        self.unshuffledPlaylistIDs = unshuffledPlaylistIDs
        self.position = max(0, position.isFinite ? position : 0)
        self.wasPaused = wasPaused
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case source
        case collectionFolder
        case playlistItems
        case playlistIndex
        case unshuffledPlaylistIDs
        case position
        case wasPaused
        case updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(
            Int.self,
            forKey: .schemaVersion
        ) ?? 1
        source = try container.decode(MediaSource.self, forKey: .source)
        collectionFolder = try container.decodeIfPresent(
            URL.self,
            forKey: .collectionFolder
        )
        playlistItems = PlaylistMutation.deduplicated(
            try container.decodeIfPresent(
                [FolderPlaylistItem].self,
                forKey: .playlistItems
            ) ?? []
        )
        playlistIndex = try container.decodeIfPresent(Int.self, forKey: .playlistIndex)
        unshuffledPlaylistIDs = try container.decodeIfPresent(
            [FolderPlaylistItem.ID].self, forKey: .unshuffledPlaylistIDs
        )
        let decodedPosition = try container.decodeIfPresent(
            TimeInterval.self,
            forKey: .position
        ) ?? 0
        position = max(0, decodedPosition.isFinite ? decodedPosition : 0)
        wasPaused = try container.decodeIfPresent(Bool.self, forKey: .wasPaused) ?? false
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
    }
}

public protocol PlaybackSessionStoring: Sendable {
    func load() throws -> PlaybackSessionRecord?
    func save(_ session: PlaybackSessionRecord) throws
    func clear() throws
}

/// A versioned, atomic Application Support document for crash-safe playback
/// restoration. Preferences intentionally live in a separate store.
public final class AtomicPlaybackSessionStore: PlaybackSessionStoring, @unchecked Sendable {
    private let lock = NSLock()
    private let fileManager: FileManager
    public let fileURL: URL

    public init(
        fileURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.fileURL = fileURL ?? Self.defaultFileURL(fileManager: fileManager)
    }

    public func load() throws -> PlaybackSessionRecord? {
        try lock.withLock {
            guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
            let data = try Data(contentsOf: fileURL)
            let record = try JSONDecoder().decode(PlaybackSessionRecord.self, from: data)
            guard (1...PlaybackSessionRecord.currentSchemaVersion).contains(
                record.schemaVersion
            ) else {
                return nil
            }
            return record
        }
    }

    public func save(_ session: PlaybackSessionRecord) throws {
        try lock.withLock {
            let directory = fileURL.deletingLastPathComponent()
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: nil
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(session)
            try data.write(to: fileURL, options: [.atomic])
        }
    }

    public func clear() throws {
        try lock.withLock {
            guard fileManager.fileExists(atPath: fileURL.path) else { return }
            try fileManager.removeItem(at: fileURL)
        }
    }

    private static func defaultFileURL(fileManager: FileManager) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("Superplayr", isDirectory: true)
            .appendingPathComponent("PlaybackSession.json", isDirectory: false)
    }
}

private extension NSLock {
    func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock()
        defer { unlock() }
        return try body()
    }
}
