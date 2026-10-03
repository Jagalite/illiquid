import Foundation
import Observation

@MainActor
@Observable
final class PlaybackDiagnostics {
    var container = "None"
    var selectedVideo = "None"
    var selectedAudio = "None"
    var selectedSubtitle = "Off"
    var videoCodec = "None"
    var audioCodec = "None"
    var subtitleCodec = "None"
    var hardwareDecoder = "Not initialized"
    var ffmpegPixelFormat = "Unknown"
    var pixelBufferFormat = "Unknown"
    var resolution = "Unknown"
    var displayAspectRatio = "Unknown"
    var frameRate = "Unknown"
    var videoTimeBase = "Unknown"
    var audioTimeBase = "Unknown"
    var videoPTS = 0.0
    var audioPTS = 0.0
    var synchronizerTime = 0.0
    var bufferedVideoDuration = 0.0
    var bufferedAudioDuration = 0.0
    var videoPacketDepth = 0
    var audioPacketDepth = 0
    var subtitlePacketDepth = 0
    var videoFrameDepth = 0
    var audioFrameDepth = 0
    var generation = 0
    var seekCount = 0
    var hardwareFallbackCount = 0
    var discardedStalePackets = 0
    var discardedStaleFrames = 0
    var rendererReady = false
    var rendererFailure: String?
    var lastRecoveryMessage: String?
    var framesSubmitted = 0
    // No trustworthy renderer-backed per-frame drop callback is wired yet.
    // Nil is deliberately distinct from a measured zero.
    var framesDropped: Int?
    var rendererStarvations = 0
    var rendererBackpressureEvents = 0
    var subtitleEventCount = 0
    var libassFontProvider = "Uninitialized"
    var registeredAttachments: [String] = []
    var attachmentDiagnostics: [String] = []
    var audioFormat = "Uninitialized"
    var audioSourceLayout = "Unknown"
    var videoRotation = 0.0
    var displayName = "No display"
    var displayBackingScale = 0.0
    var currentEDRHeadroom = 1.0
    var potentialEDRHeadroom = 1.0
    var sleepCount = 0
    var wakeCount = 0
    var displayChangeCount = 0
    var fullscreenTransitionCount = 0
    var residentMemoryBytes: UInt64 = 0
    var peakResidentMemoryBytes: UInt64 = 0
    var isHardwareDecoded = false
    var isCopiedHardwarePath = false
    var isNearZeroCopy = false
    var colorPrimaries = "Unknown"
    var transferCharacteristic = "Unknown"
    var matrixCoefficients = "Unknown"
    var colorRange = "Unknown"
    var hasMasteringDisplayMetadata = false
    var hasContentLightMetadata = false
    var messages: [String] = []

    var audioVideoDifference: Double { audioPTS - videoPTS }

    var residentMemoryDescription: String {
        String(format: "%.1f MiB / %.1f MiB peak",
               Double(residentMemoryBytes) / 1_048_576,
               Double(peakResidentMemoryBytes) / 1_048_576)
    }

    func record(_ message: String) {
        messages.append(message)
        if messages.count > 200 {
            messages.removeFirst(messages.count - 200)
        }
    }

    func configure(media: FFmpegMediaInfo) {
        container = media.containerName
        if let video = media.videoStreams.first(where: { $0.index == media.selectedVideoIndex }) {
            selectedVideo = video.displayName
            videoCodec = video.codecName
            resolution = video.codedSize.map {
                "\(Int($0.width)) × \(Int($0.height))"
            } ?? "Unknown"
            frameRate = video.averageFrameRate.map {
                String(format: "%.3f fps", $0)
            } ?? "Unknown"
            videoTimeBase = "\(video.timeBase.numerator)/\(video.timeBase.denominator)"
        }
        if let audio = media.audioStreams.first(where: { $0.index == media.selectedAudioIndex }) {
            selectedAudio = audio.displayName
            audioCodec = audio.codecName
            audioTimeBase = "\(audio.timeBase.numerator)/\(audio.timeBase.denominator)"
            audioSourceLayout = audio.channelLayout ?? "Unknown"
        }
        if let subtitle = media.subtitleStreams.first(where: {
            $0.index == media.selectedSubtitleIndex
        }) {
            selectedSubtitle = subtitle.displayName
            subtitleCodec = subtitle.codecName
        }
        registeredAttachments = media.attachments.map(\.filename)
        videoRotation = media.videoStreams.first {
            $0.index == media.selectedVideoIndex
        }?.rotationDegrees ?? 0
    }
}
