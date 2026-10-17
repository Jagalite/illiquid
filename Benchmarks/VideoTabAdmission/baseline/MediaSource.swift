import Foundation

/// A media source understood by the product, independent of the playback
/// backend used to open it.
public enum MediaSource: Hashable, Codable, Sendable {
    case localFile(URL)
    case remoteStream(URL)

    public var url: URL {
        switch self {
        case let .localFile(url), let .remoteStream(url): url
        }
    }

    public var isRemote: Bool {
        if case .remoteStream = self { true } else { false }
    }

    public init?(url: URL) {
        if url.isFileURL {
            self = .localFile(url)
            return
        }

        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            return nil
        }
        self = .remoteStream(url)
    }

    public func representsSameResource(as other: MediaSource) -> Bool {
        switch (self, other) {
        case let (.localFile(lhs), .localFile(rhs)):
            NormalizedFileURL.representsSameFile(lhs, rhs)
        case let (.remoteStream(lhs), .remoteStream(rhs)):
            lhs.absoluteURL.absoluteString == rhs.absoluteURL.absoluteString
        default:
            false
        }
    }
}

public enum MediaSourceOrigin: String, Codable, Sendable {
    case userSelected
    case restoredSession
}

/// One authorized attempt to load a source. Remote origins are never valid for
/// silent session restoration; that invariant is enforced when the request is
/// created instead of being left to backend call-site convention.
public struct MediaLoadRequest: Equatable, Sendable {
    public let source: MediaSource
    public let origin: MediaSourceOrigin

    public init?(source: MediaSource, origin: MediaSourceOrigin) {
        guard !(source.isRemote && origin == .restoredSession) else { return nil }
        self.source = source
        self.origin = origin
    }
}
