import Foundation
import SuperplayrCore

struct PreparedExternalSubtitle {
    let url: URL
    let data: Data?
    let tracks: [MediaTrack]
    let bitmapStreams: [FFmpegStreamInfo]
    let versions: [MediaContentVersion?]

    var track: MediaTrack { tracks[0] }
    var source: NativeSubtitleSource { source(for: track.id)! }

    func source(for id: Int64) -> NativeSubtitleSource? {
        guard tracks.contains(where: { $0.id == id }) else { return nil }
        if bitmapStreams.isEmpty { return .external(url: url) }
        guard let stream = bitmapStreams.first(where: { Self.trackID($0.index) == id }) else { return nil }
        return .externalBitmap(url: url, streamIndex: stream.index)
    }

    static func trackID(_ index: Int32) -> Int64 { Int64.max - Int64(index) }

    func verifyVersions() throws {
        guard !bitmapStreams.isEmpty else { return }
        let paths = [url, url.deletingPathExtension().appendingPathExtension("sub")]
        guard zip(paths, versions).allSatisfy({ path, version in
            version != nil && NativeFileContentVersion.read(path) == version
        }) else { throw PresentationError("The VobSub pair changed while it was being opened.") }
    }

    static func prepare(url: URL, encoding: SubtitleFallbackEncoding) throws -> Self {
        if url.pathExtension.lowercased() != "idx" {
            return Self(url: url, data: try SubtitlePipeline.prepareExternalData(url: url, fallbackEncoding: encoding),
                tracks: [.init(id: Int64.max, kind: .subtitle, title: url.deletingPathExtension().lastPathComponent,
                               codec: url.pathExtension.lowercased(), isExternal: true, externalFilename: url.lastPathComponent)],
                bitmapStreams: [], versions: [])
        }
        let companion = url.deletingPathExtension().appendingPathExtension("sub")
        let indexSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard indexSize > 0, indexSize <= 8 * 1_024 * 1_024,
              FileManager.default.fileExists(atPath: companion.path) else {
            throw PresentationError("Open a VobSub .idx file with its matching .sub file in the same folder (index limit: 8 MiB).")
        }
        let versions = [url, companion].map(NativeFileContentVersion.read)
        let input = try FFmpegInputExecutor(url: url)
        let streams = input.mediaInfo.subtitleStreams
        guard !streams.isEmpty, streams.count <= 32,
              streams.allSatisfy({ $0.codecName == "dvd_subtitle" || $0.codecName == "dvdsub" }) else {
            throw PresentationError("The VobSub index has no supported DVD subtitle tracks or exceeds 32 tracks.")
        }
        let result = Self(url: url, data: nil, tracks: streams.map { stream in
            MediaTrack(id: trackID(stream.index), kind: .subtitle,
                title: stream.language.map { "\(url.deletingPathExtension().lastPathComponent) — \($0)" }
                    ?? "\(url.deletingPathExtension().lastPathComponent) — Track \(stream.index + 1)",
                languageCode: stream.language, codec: stream.codecName,
                isExternal: true, externalFilename: url.lastPathComponent)
        }, bitmapStreams: streams, versions: versions)
        try result.verifyVersions()
        return result
    }
}
