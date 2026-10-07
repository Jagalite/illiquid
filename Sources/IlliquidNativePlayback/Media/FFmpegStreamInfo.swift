import CFFmpeg
import CoreGraphics
import Foundation

func stringFromCStringBuffer(_ buffer: [CChar]) -> String {
    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
}

enum NativeStreamKind: String, Codable, Sendable {
    case video
    case audio
    case subtitle
    case attachment
    case other
}

enum NativeSubtitleCapability: Equatable, Sendable {
    case text
    case bitmap
    case bitmapUnsupported(codec: String)
    case unsupported(codec: String)

    static func classify(codecName: String) -> Self {
        switch codecName.lowercased() {
        case "ass", "ssa", "subrip", "srt", "text", "webvtt", "mov_text":
            .text
        case "hdmv_pgs_subtitle", "pgssub", "dvd_subtitle", "dvdsub", "dvb_subtitle", "dvbsub":
            .bitmap
        case "xsub":
            .bitmapUnsupported(codec: codecName)
        default:
            .unsupported(codec: codecName)
        }
    }

    var isPlayable: Bool {
        switch self {
        case .text, .bitmap: true
        case .bitmapUnsupported, .unsupported: false
        }
    }
}

enum NativeInterlaceMode: String, Equatable, Sendable {
    case progressive
    case topFieldFirst
    case bottomFieldFirst
    case mixedOrUnknown

    init(ffmpegFieldOrder: Int32) {
        switch ffmpegFieldOrder {
        case 1: self = .progressive
        case 2, 4: self = .topFieldFirst
        case 3, 5: self = .bottomFieldFirst
        default: self = .mixedOrUnknown
        }
    }

    var requiresDeinterlacing: Bool {
        self == .topFieldFirst || self == .bottomFieldFirst
    }
}

enum NativeTrackIDMapping {
    static func streamIndex(for trackID: Int64) -> Int32? {
        guard trackID > 0, trackID <= Int64(Int32.max) + 1 else { return nil }
        return Int32(trackID - 1)
    }

    static func trackID(for streamIndex: Int32) -> Int64 {
        Int64(streamIndex) + 1
    }
}

struct FFmpegStreamInfo: Identifiable, Equatable, Sendable {
    let index: Int32
    let kind: NativeStreamKind
    let codecID: Int32
    let codecName: String
    let title: String?
    let language: String?
    let timeBase: FFmpegRational
    let duration: Double?
    let disposition: Int32
    let codedSize: CGSize?
    let pixelAspectRatio: CGSize?
    let averageFrameRate: Double?
    let sampleRate: Int?
    let channelCount: Int?
    let channelLayout: String?
    let rotationDegrees: Double
    let isMirrored: Bool
    let interlaceMode: NativeInterlaceMode

    var id: Int32 { index }

    var displaySize: CGSize? {
        guard let codedSize else { return nil }
        let aspect = pixelAspectRatio ?? CGSize(width: 1, height: 1)
        let unrotated = CGSize(
            width: codedSize.width * aspect.width / max(aspect.height, 1),
            height: codedSize.height
        )
        let normalized = abs(rotationDegrees.truncatingRemainder(dividingBy: 180))
        return abs(normalized - 90) < 1
            ? CGSize(width: unrotated.height, height: unrotated.width)
            : unrotated
    }

    var displayName: String {
        let components = [
            title,
            language,
            codecName,
        ].compactMap { value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        return components.isEmpty
            ? "\(kind.rawValue.capitalized) \(index)"
            : components.joined(separator: " — ")
    }

    var subtitleCapability: NativeSubtitleCapability? {
        kind == .subtitle ? .classify(codecName: codecName) : nil
    }
}

struct FFmpegMediaInfo: Sendable {
    enum TimelineValue: Equatable, Sendable {
        case valid(Double)
        case unknown
        case invalid
    }

    let url: URL
    let containerName: String
    let duration: Double
    let startTime: Double
    let durationStatus: TimelineValue
    let startTimeStatus: TimelineValue
    let streams: [FFmpegStreamInfo]
    let chapters: [(title: String?, start: Double, end: Double)]
    let attachments: [FontAttachment]
    let selectedVideoIndex: Int32?
    let selectedAudioIndex: Int32?
    let selectedSubtitleIndex: Int32?

    var videoStreams: [FFmpegStreamInfo] { streams.filter { $0.kind == .video } }
    var audioStreams: [FFmpegStreamInfo] { streams.filter { $0.kind == .audio } }
    var subtitleStreams: [FFmpegStreamInfo] { streams.filter { $0.kind == .subtitle } }
}
