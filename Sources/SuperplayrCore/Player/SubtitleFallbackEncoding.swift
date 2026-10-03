import Foundation

public enum SubtitleFallbackEncoding: String, CaseIterable, Codable, Sendable {
    case unicodeOnly, windows1252, windows1251, shiftJIS, isoLatin1

    public var title: String {
        switch self {
        case .unicodeOnly: "Unicode only"
        case .windows1252: "Western (Windows-1252)"
        case .windows1251: "Cyrillic (Windows-1251)"
        case .shiftJIS: "Japanese (Shift JIS)"
        case .isoLatin1: "Western (ISO-8859-1)"
        }
    }

    public var stringEncoding: String.Encoding? {
        switch self {
        case .unicodeOnly: nil
        case .windows1252: .windowsCP1252
        case .windows1251: .windowsCP1251
        case .shiftJIS: .shiftJIS
        case .isoLatin1: .isoLatin1
        }
    }
}
