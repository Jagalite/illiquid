import Foundation

/// The local source Illiquid should reopen on its next launch.
///
/// A folder is kept distinct from its last watched file so relaunching rebuilds
/// the folder playlist instead of restoring a single, disconnected episode.
public enum PlaybackRestoreTarget: Codable, Equatable, Sendable {
    case file(URL)
    case folder(URL)

    public var url: URL {
        switch self {
        case let .file(url), let .folder(url): url
        }
    }

    private enum Kind: String, Codable {
        case file
        case folder
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case path
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        let path = try container.decode(String.self, forKey: .path)
        let url = URL(fileURLWithPath: path, isDirectory: kind == .folder)

        switch kind {
        case .file: self = .file(url)
        case .folder: self = .folder(url)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case let .file(url):
            try container.encode(Kind.file, forKey: .kind)
            try container.encode(url.path, forKey: .path)
        case let .folder(url):
            try container.encode(Kind.folder, forKey: .kind)
            try container.encode(url.path, forKey: .path)
        }
    }
}
