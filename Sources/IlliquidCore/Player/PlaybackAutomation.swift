import Foundation

public enum PlaybackAutomationError: Error, Equatable, LocalizedError {
    case invalidFile, invalidTimestamp, invalidReference, changedFile, busy, superseded, timedOut, noPlayback, failed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidFile: "Choose accessible local media files; folders and remote URLs are not accepted by this action."
        case .invalidTimestamp: "The timestamp must be a finite, nonnegative number within the media timeline."
        case .invalidReference: "This playback reference is invalid or uses an unsupported version."
        case .changedFile: "The file no longer matches this playback reference. Open the file directly to use its current contents."
        case .busy: "Too many automation requests are waiting. Retry after the current action finishes."
        case .superseded: "A newer playback command superseded this action."
        case .timedOut: "The playback action did not finish in time. Its last valid recovery state has been retained."
        case .noPlayback: "There is no settled local playback position to return."
        case .failed(let message): message
        }
    }
}

/// A durable *media and time* reference, not authority over a live player session.
/// It deliberately contains no access-granting bookmarks or remote credentials.
/// Reopening verifies the file version; a moved file must be located explicitly.
public struct PlaybackReference: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let url: URL
    public let position: TimeInterval
    public let contentVersion: MediaContentVersion

    public init(url: URL, position: TimeInterval, contentVersion: MediaContentVersion) throws {
        guard PlaybackAutomationPolicy.isLocalFileURL(url),
              let url = NormalizedFileURL.normalize(url), url.path.utf8.count <= 4_096 else {
            throw PlaybackAutomationError.invalidFile
        }
        guard position.isFinite, position >= 0,
              Int64(exactly: (position * 1_000_000).rounded()) != nil else {
            throw PlaybackAutomationError.invalidTimestamp
        }
        schemaVersion = 1
        self.url = url
        self.position = position
        self.contentVersion = contentVersion
    }

    public func encodedIdentifier() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= 8_192 else { throw PlaybackAutomationError.invalidReference }
        return data.base64EncodedString()
    }

    public static func decodeIdentifier(_ value: String) throws -> Self {
        guard value.utf8.count <= 12_000, let data = Data(base64Encoded: value), data.count <= 8_192 else {
            throw PlaybackAutomationError.invalidReference
        }
        do { return try JSONDecoder().decode(Self.self, from: data) }
        catch { throw PlaybackAutomationError.invalidReference }
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, url, position, contentVersion }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(Int.self, forKey: .schemaVersion) == 1 else {
            throw PlaybackAutomationError.invalidReference
        }
        try self.init(url: values.decode(URL.self, forKey: .url),
            position: values.decode(Double.self, forKey: .position),
            contentVersion: values.decode(MediaContentVersion.self, forKey: .contentVersion))
    }
}

public enum PlaybackAutomationPolicy {
    public static let maximumFiles = 256
    public static let maximumPendingRequests = 32

    public static func isLocalFileURL(_ url: URL) -> Bool {
        url.isFileURL && (url.host == nil || url.host == "" || url.host?.lowercased() == "localhost")
            && url.user == nil && url.password == nil && url.port == nil
            && url.query == nil && url.fragment == nil && !url.path.utf8.contains(0)
            && !(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath.lowercased().contains("%00") ?? true)
    }

    public static func validateTimestamp(_ value: Double) throws {
        guard value.isFinite, value >= 0, Int64(exactly: (value * 1_000_000).rounded()) != nil else {
            throw PlaybackAutomationError.invalidTimestamp
        }
    }

    /// Preserve caller order and the first occurrence. This is not the Finder
    /// date-added sort policy. Filesystem access happens later, off the UI actor.
    public static func orderedLocalURLs(_ urls: [URL]) throws -> [URL] {
        guard !urls.isEmpty, urls.count <= maximumFiles else { throw PlaybackAutomationError.invalidFile }
        var seen = Set<String>()
        var result: [URL] = []
        for url in urls {
            guard isLocalFileURL(url), let normalized = NormalizedFileURL.normalize(url),
                  normalized.path.utf8.count <= 4_096,
                  MediaFileSupport.isSupportedMediaFile(normalized),
                  let key = NormalizedFileURL.persistenceKey(for: normalized) else {
                throw PlaybackAutomationError.invalidFile
            }
            if seen.insert(key).inserted { result.append(normalized) }
        }
        return result
    }
}
