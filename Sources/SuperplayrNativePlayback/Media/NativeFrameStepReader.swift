import Foundation
import CoreMedia

/// Serialized, on-demand timestamp discovery. Keeps one decoder and two scalar
/// timestamps for a request, with no persistent frame history or decoder.
actor NativeFrameStepReader {
    func target(url: URL, position: Double, direction: Int) throws -> Double? {
        let interrupt = FFmpegInterruptState()
        let token = FFmpegInputEffectToken(rawValue: 1)
        interrupt.begin(token)
        let deadline = DispatchWorkItem { _ = interrupt.cancel(token) }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 8, execute: deadline)
        defer { deadline.cancel(); interrupt.end(token) }
        let demuxer = try FFmpegDemuxer(url: url, interruptState: interrupt)
        guard let stream = demuxer.mediaInfo.videoStreams.first(where: { $0.index == demuxer.mediaInfo.selectedVideoIndex }),
              let parameters = demuxer.codecParameters(streamIndex: stream.index) else {
            throw PresentationError("This file has no video frames.")
        }
        let decoder = try VideoDecoder(parameters: parameters, stream: stream,
            preferHardware: false, timelineOriginSeconds: demuxer.mediaInfo.startTime,
            softwareOutputMode: .bgra, softwareDecoderThreadCount: 2,
            softwarePlanarOutputMaximumBufferCount: 2)
        let started = ProcessInfo.processInfo.systemUptime
        var lookBehind = 0.01
        repeat {
            try Task.checkCancellation()
            let origin = max(0, position - lookBehind)
            decoder.flush()
            try demuxer.seek(to: origin + demuxer.mediaInfo.startTime, exact: false)
            var previous: Double?
            var next: Double?
            var reachedCurrent = false
            var eof = false
            func receive(_ frame: NativeDecodedVideoFrame) {
                let pts = frame.presentationTime.seconds
                guard pts.isFinite else { return }
                if pts < position - 0.000001 { previous = pts }
                else { reachedCurrent = true }
                if pts > position + 0.000001, next == nil { next = pts }
            }
            func keepDecoding() -> Bool {
                !Task.isCancelled && ProcessInfo.processInfo.systemUptime - started < 8
            }
            for _ in 0..<50_000 {
                guard keepDecoding() else { throw CancellationError() }
                guard let packet = try demuxer.readPacket(generation: 1) else {
                    try decoder.drain(generation: 1, while: keepDecoding, emit: receive)
                    eof = true
                    break
                }
                if packet.streamIndex == stream.index {
                    try decoder.decode(packet, while: keepDecoding, emit: receive)
                }
                if direction > 0 ? next != nil : reachedCurrent { break }
            }
            try Task.checkCancellation()
            if direction > 0 {
                if let next { return next }
                if eof { return nil }
                throw PresentationError("Frame step exceeded its decode budget.")
            }
            if let previous, reachedCurrent || eof { return previous }
            if origin == 0 { return nil }
            lookBehind = max(2, lookBehind * 2)
        } while ProcessInfo.processInfo.systemUptime - started < 8
        throw PresentationError("Frame step exceeded its decode budget.")
    }
}
