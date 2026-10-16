import Foundation

public enum MediaTrackKind: String, Codable, CaseIterable, Sendable {
    case audio
    case subtitle
}

public struct MediaTrack: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: Int64
    public let kind: MediaTrackKind
    public let title: String?
    public let languageCode: String?
    public let codec: String?
    public let isDefault: Bool
    public let isForced: Bool
    public let isExternal: Bool
    public let externalFilename: String?

    public var displayName: String {
        if let title = title?.nonEmpty {
            return title
        }

        if let languageCode = languageCode?.nonEmpty {
            return Locale.current.localizedString(forLanguageCode: languageCode) ?? languageCode
        }

        return "\(kind == .audio ? "Audio" : "Subtitle") \(id)"
    }

    public init(
        id: Int64,
        kind: MediaTrackKind,
        title: String? = nil,
        languageCode: String? = nil,
        codec: String? = nil,
        isDefault: Bool = false,
        isForced: Bool = false,
        isExternal: Bool = false,
        externalFilename: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title?.nonEmpty
        self.languageCode = languageCode?.nonEmpty
        self.codec = codec?.nonEmpty
        self.isDefault = isDefault
        self.isForced = isForced
        self.isExternal = isExternal
        self.externalFilename = externalFilename?.nonEmpty
    }
}

/// A C-free representation of one entry in mpv's `track-list`. The Player
/// module converts raw mpv properties into this value before parsing it.
public struct MediaTrackDescriptor: Equatable, Sendable {
    public var id: Int64?
    public var type: String?
    public var title: String?
    public var language: String?
    public var codec: String?
    public var isDefault: Bool
    public var isForced: Bool
    public var isExternal: Bool
    public var externalFilename: String?

    public init(
        id: Int64?,
        type: String?,
        title: String? = nil,
        language: String? = nil,
        codec: String? = nil,
        isDefault: Bool = false,
        isForced: Bool = false,
        isExternal: Bool = false,
        externalFilename: String? = nil
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.language = language
        self.codec = codec
        self.isDefault = isDefault
        self.isForced = isForced
        self.isExternal = isExternal
        self.externalFilename = externalFilename
    }
}

public enum MediaTrackParser {
    public static func parse(_ descriptors: [MediaTrackDescriptor]) -> [MediaTrack] {
        descriptors.compactMap { descriptor in
            guard let id = descriptor.id, id > 0,
                  let rawType = descriptor.type?.lowercased()
            else {
                return nil
            }

            let kind: MediaTrackKind
            switch rawType {
            case "audio": kind = .audio
            case "sub", "subtitle": kind = .subtitle
            default: return nil
            }

            return MediaTrack(
                id: id,
                kind: kind,
                title: descriptor.title,
                languageCode: descriptor.language,
                codec: descriptor.codec,
                isDefault: descriptor.isDefault,
                isForced: descriptor.isForced,
                isExternal: descriptor.isExternal,
                externalFilename: descriptor.externalFilename
            )
        }
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
