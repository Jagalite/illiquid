import AppKit
import AVFoundation
import CoreMedia
import Foundation
import IOSurface

final class SampleBufferVideoPresenter: @unchecked Sendable {
    struct FrameIdentity: Sendable {
        let surfaceID: UInt32?
        let bufferID: UInt
        let time: Double
        let generation: Int
    }
    private let identityLock = NSLock()
    private var frameIdentities: [FrameIdentity] = []

    func adjacentTime(to frame: FrameIdentity, direction: Int) -> Double? {
        identityLock.withLock {
            let times = frameIdentities.lazy.filter { $0.generation == frame.generation }.map(\.time)
            return direction > 0
                ? times.filter { $0 > frame.time + 0.000001 }.min()
                : times.filter { $0 < frame.time - 0.000001 }.max()
        }
    }

    func identity(for buffer: CVPixelBuffer) -> FrameIdentity? {
        let surface = CVPixelBufferGetIOSurface(buffer).map { IOSurfaceGetID($0.takeUnretainedValue()) }
        let bufferID = UInt(bitPattern: Unmanaged.passUnretained(buffer).toOpaque())
        return identityLock.withLock {
            frameIdentities.last {
                if let surface { return $0.surfaceID == surface }
                return $0.bufferID == bufferID
            }
        }
    }

    let displayLayer: AVSampleBufferDisplayLayer
    let renderer: AVSampleBufferVideoRenderer

    init() {
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
        displayLayer = layer
        renderer = layer.sampleBufferRenderer
    }

    var isReady: Bool { renderer.isReadyForMoreMediaData }
    var recommendedPixelBufferAttributes: [String: Any] {
        renderer.recommendedPixelBufferAttributes.rawAttributes.reduce(into: [:]) {
            $0[$1.key] = $1.value
        }
    }
    var requiresFlushToResumeDecoding: Bool {
        renderer.requiresFlushToResumeDecoding
    }

    var failureDescription: String? {
        renderer.status == .failed
            ? renderer.error?.localizedDescription ?? "Video renderer failed"
            : nil
    }

    func requestMediaDataWhenReady(
        on queue: DispatchQueue,
        using block: @escaping @Sendable () -> Void
    ) {
        renderer.requestMediaDataWhenReady(on: queue, using: block)
    }

    func stopRequestingMediaData() {
        renderer.stopRequestingMediaData()
    }

    func enqueue(
        _ frame: NativeDecodedVideoFrame,
        displayImmediately: Bool = false
    ) throws {
        if requiresFlushToResumeDecoding {
            throw PresentationRecoveryRequiredError.requiresFlushToResumeDecoding
        }
        var formatDescription: CMVideoFormatDescription?
        try withNativeVideoSignpost("VideoFormatDescriptionCreate") {
            try checkOSStatus(
                CMVideoFormatDescriptionCreateForImageBuffer(
                    allocator: kCFAllocatorDefault,
                    imageBuffer: frame.pixelBuffer,
                    formatDescriptionOut: &formatDescription
                ),
                operation: "Create video format description"
            )
        }
        guard let formatDescription else {
            throw PresentationError("Video format description was not created")
        }

        var timing = CMSampleTimingInfo(
            duration: frame.duration,
            presentationTimeStamp: frame.presentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        try withNativeVideoSignpost("VideoSampleBufferCreate") {
            try checkOSStatus(
                CMSampleBufferCreateReadyWithImageBuffer(
                    allocator: kCFAllocatorDefault,
                    imageBuffer: frame.pixelBuffer,
                    formatDescription: formatDescription,
                    sampleTiming: &timing,
                    sampleBufferOut: &sampleBuffer
                ),
                operation: "Create video sample buffer"
            )
        }
        guard let sampleBuffer else {
            throw PresentationError("Video sample buffer was not created")
        }
        frame.planarOwnershipToken?.attachRendererSampleLifetime(to: sampleBuffer)
        if displayImmediately {
            CMSetAttachment(
                sampleBuffer,
                key: kCMSampleAttachmentKey_DisplayImmediately,
                value: kCFBooleanTrue,
                attachmentMode: kCMAttachmentMode_ShouldPropagate
            )
        }
        let identity = FrameIdentity(
            surfaceID: CVPixelBufferGetIOSurface(frame.pixelBuffer).map { IOSurfaceGetID($0.takeUnretainedValue()) },
            bufferID: UInt(bitPattern: Unmanaged.passUnretained(frame.pixelBuffer).toOpaque()),
            time: frame.presentationTime.seconds, generation: frame.generation)
        identityLock.withLock {
            if frameIdentities.count == 128 { frameIdentities.removeFirst() }
            frameIdentities.append(identity)
        }
        withNativeVideoSignpost("VideoRendererEnqueue") {
            renderer.enqueue(sampleBuffer)
        }
        frame.planarOwnershipToken?.transition(to: .submitted)
        if let failureDescription {
            throw PresentationError(failureDescription)
        }
    }

    func flush(
        removeDisplayedImage: Bool = true,
        completion: (@Sendable () -> Void)? = nil
    ) {
        identityLock.withLock { frameIdentities.removeAll(keepingCapacity: true) }
        renderer.flush(
            removingDisplayedImage: removeDisplayedImage,
            completionHandler: completion
        )
    }
}

enum PresentationRecoveryRequiredError: LocalizedError {
    case requiresFlushToResumeDecoding

    var errorDescription: String? {
        "The video presentation sink requires a scoped flush before decoding can resume."
    }
}

struct PresentationError: LocalizedError {
    let message: String

    init(_ message: String) { self.message = message }

    var errorDescription: String? { message }
}

func checkOSStatus(_ status: OSStatus, operation: String) throws {
    guard status == noErr else {
        throw NSError(
            domain: NSOSStatusErrorDomain,
            code: Int(status),
            userInfo: [NSLocalizedDescriptionKey: operation]
        )
    }
}
