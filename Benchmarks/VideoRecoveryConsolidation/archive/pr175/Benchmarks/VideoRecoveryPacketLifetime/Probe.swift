import CFFmpeg
import Foundation

// Observe real AVBuffer destruction. The receipt owns no packet or buffer.
private final class ReleaseReceipt: @unchecked Sendable {
    let payloadBytes: Int
    let storageBytes: Int
    private let lock = NSLock()
    private var releases = 0

    init(payloadBytes: Int, storageBytes: Int) {
        self.payloadBytes = payloadBytes
        self.storageBytes = storageBytes
    }

    func released() { lock.withLock { releases += 1 } }
    var count: Int { lock.withLock { releases } }
}

private let releasePayload: @convention(c) (
    UnsafeMutableRawPointer?, UnsafeMutablePointer<UInt8>?
) -> Void = { opaque, bytes in
    if let opaque {
        Unmanaged<ReleaseReceipt>.fromOpaque(opaque).takeRetainedValue().released()
    }
    av_free(bytes)
}

@inline(never)
private func makePacket(
    bytes: Int, keyframe: Bool, generation: Int = 1
) throws -> (FFmpegPacket, ReleaseReceipt) {
    var header = av_packet_alloc()
    guard let packet = header else { throw FFmpegError(operation: "fixture header", code: -12) }
    defer { av_packet_free(&header) }
    let storageBytes = bytes + Int(AV_INPUT_BUFFER_PADDING_SIZE)
    guard let allocation = av_mallocz(storageBytes) else {
        throw FFmpegError(operation: "fixture payload", code: -12)
    }
    let data = allocation.assumingMemoryBound(to: UInt8.self)
    data[0] = 37
    data[bytes - 1] = 83
    let receipt = ReleaseReceipt(payloadBytes: bytes, storageBytes: storageBytes)
    let opaque = Unmanaged.passRetained(receipt).toOpaque()
    guard let buffer = av_buffer_create(data, storageBytes, releasePayload, opaque, 0) else {
        Unmanaged<ReleaseReceipt>.fromOpaque(opaque).release()
        av_free(allocation)
        throw FFmpegError(operation: "fixture AVBuffer", code: -12)
    }
    packet.pointee.buf = buffer
    packet.pointee.data = data
    packet.pointee.size = Int32(bytes)
    packet.pointee.flags = keyframe ? AV_PKT_FLAG_KEY : 0
    packet.pointee.pts = 90_000
    packet.pointee.dts = 87_000
    packet.pointee.duration = 3_000
    packet.pointee.stream_index = 2
    return (
        try FFmpegPacket(taking: &header, timeBase: AVRational(num: 1, den: 90_000), generation: generation),
        receipt
    )
}

// Separate frames ensure no fixture-local FFmpegPacket survives into measurement.
@inline(never)
private func fill(
    _ recovery: VideoRecoveryPacketBuffer, count: Int, bytes: Int, generation: Int = 1
) throws -> [ReleaseReceipt] {
    var receipts: [ReleaseReceipt] = []
    for index in 0..<count {
        let (packet, receipt) = try makePacket(bytes: bytes, keyframe: index == 0, generation: generation)
        recovery.record(packet)
        receipts.append(receipt)
    }
    return receipts
}

private func drain(
    _ recovery: VideoRecoveryPacketBuffer, generation: Int = 1, _ body: () throws -> Void
) rethrows {
    #if BASELINE
    // The old MediaSession calls drain without retiring its recovery GOP.
    // The exact old packet/buffer implementation is compiled without edits.
    try body()
    #else
    try recovery.retireAfterSuccessfulDrain(generation: generation, body)
    #endif
}

private struct SuccessObservation: Codable {
    let name: String
    let packetCount: Int
    let payloadBytes: Int
    let requestedStorageBytes: Int
    let releaseCallbacksDuringDrain: Int
    let livePayloadBytesAfterDrain: Int
    let liveStorageBytesAfterDrain: Int
    let releaseCallbacksAfterReset: Int
    let everyAllocationReleasedExactlyOnce: Bool
}

private struct ControlObservation: Codable {
    let name: String
    let checks: Int
}

private enum ExpectedFailure: Error { case decoder }

@main
private struct Probe {
    static func main() throws {
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            checks += 1
            precondition(condition, message)
        }
        check(avcodec_version() == probe_avcodec_header_version(), "libavcodec header/runtime mismatch")
        check(avutil_version() == probe_avutil_header_version(), "libavutil header/runtime mismatch")
        #if BASELINE
        let baseline = true
        let variant = "baseline"
        #else
        let baseline = false
        let variant = "candidate"
        #endif
        var success: [SuccessObservation] = []
        var controls: [ControlObservation] = []

        for (name, count, bytes) in [
            ("4KiB-final-GOP", 4, 1_024),
            ("1MiB-final-GOP", 16, 65_536),
            ("32MiB-final-GOP", 512, 65_536),
        ] {
            let recovery = VideoRecoveryPacketBuffer()
            let receipts = try fill(recovery, count: count, bytes: bytes)
            check(receipts.allSatisfy { $0.count == 0 }, "fixture was not retained before drain")
            var duringDrain = -1
            drain(recovery) {
                duringDrain = receipts.reduce(0) { $0 + $1.count }
                check(duringDrain == 0, "recovery storage released before drain completed")
            }
            let livePayload = receipts.filter { $0.count == 0 }.reduce(0) { $0 + $1.payloadBytes }
            let liveStorage = receipts.filter { $0.count == 0 }.reduce(0) { $0 + $1.storageBytes }
            check(receipts.allSatisfy { $0.count == (baseline ? 0 : 1) }, "unexpected post-drain ownership")
            check(livePayload == (baseline ? count * bytes : 0), "unexpected retained payload size")
            // Repeated successful EOF is harmless; the object remains alive.
            drain(recovery) {}
            recovery.reset()
            check(receipts.allSatisfy { $0.count == 1 }, "reset leaked or freed a payload twice")
            success.append(SuccessObservation(
                name: name, packetCount: count, payloadBytes: count * bytes,
                requestedStorageBytes: receipts.reduce(0) { $0 + $1.storageBytes },
                releaseCallbacksDuringDrain: duringDrain,
                livePayloadBytesAfterDrain: livePayload, liveStorageBytesAfterDrain: liveStorage,
                releaseCallbacksAfterReset: receipts.reduce(0) { $0 + $1.count },
                everyAllocationReleasedExactlyOnce: receipts.allSatisfy { $0.count == 1 }
            ))
            withExtendedLifetime(recovery) {}
        }

        for cancellation in [false, true] {
            let start = checks
            let recovery = VideoRecoveryPacketBuffer()
            let receipts = try fill(recovery, count: 4, bytes: 65_536)
            var caught = false
            do {
                try drain(recovery) {
                    check(receipts.allSatisfy { $0.count == 0 }, "failed drain lost recovery input")
                    if cancellation { throw CancellationError() }
                    throw ExpectedFailure.decoder
                }
            } catch is CancellationError {
                check(cancellation, "wrong error escaped")
                caught = true
            } catch ExpectedFailure.decoder {
                check(!cancellation, "wrong error escaped")
                caught = true
            }
            check(caught, "drain swallowed its error")
            check(receipts.allSatisfy { $0.count == 0 }, "throwing drain retired recovery input")
            func consumeReplay() {
                let replay = recovery.takeReplayPackets(generation: 1)
                check(replay.count == 4 && replay.first?.isKeyframe == true, "recovery GOP unavailable after error")
                check(replay.allSatisfy { $0.byteCount == 65_536 && $0.pointer?.pointee.data[0] == 37 }, "replay payload changed")
                check(receipts.allSatisfy { $0.count == 0 }, "replay did not own its payloads")
                withExtendedLifetime(replay) {}
            }
            consumeReplay()
            check(receipts.allSatisfy { $0.count == 1 }, "consumed replay did not release each buffer")
            controls.append(ControlObservation(name: cancellation ? "throwing-cancellation" : "decoder-error", checks: checks - start))
            withExtendedLifetime(recovery) {}
        }

        for changesDuringDrain in [false, true] {
            let start = checks
            let recovery = VideoRecoveryPacketBuffer()
            let old = try fill(recovery, count: 2, bytes: 1_024, generation: 1)
            var newer: [ReleaseReceipt] = []
            if !changesDuringDrain { newer = try fill(recovery, count: 3, bytes: 2_048, generation: 2) }
            try drain(recovery, generation: 1) {
                if changesDuringDrain { newer = try fill(recovery, count: 3, bytes: 2_048, generation: 2) }
            }
            check(old.allSatisfy { $0.count == 1 }, "replaced generation leaked")
            check(newer.allSatisfy { $0.count == 0 }, "stale EOF retired the new generation")
            func consumeCurrentReplay() {
                let replay = recovery.takeReplayPackets(generation: 2)
                check(replay.count == 3 && replay.allSatisfy { $0.generation == 2 }, "new generation replay changed")
                withExtendedLifetime(replay) {}
            }
            consumeCurrentReplay()
            check(newer.allSatisfy { $0.count == 1 }, "new generation payloads were not released")
            controls.append(ControlObservation(name: changesDuringDrain ? "seek-during-drain" : "stale-generation-EOF", checks: checks - start))
            withExtendedLifetime(recovery) {}
        }

        do {
            let start = checks
            let recovery = VideoRecoveryPacketBuffer()
            @inline(never) func fillAndClone() throws -> (UnsafeMutablePointer<AVPacket>, ReleaseReceipt) {
                let (packet, receipt) = try makePacket(bytes: 1_048_576, keyframe: true)
                recovery.record(packet)
                guard let clone = av_packet_clone(packet.pointer) else {
                    throw FFmpegError(operation: "fixture clone", code: -12)
                }
                return (clone, receipt)
            }
            let (clone, receipt) = try fillAndClone()
            var borrowed: UnsafeMutablePointer<AVPacket>? = clone
            drain(recovery) {}
            check(receipt.count == 0, "EOF freed a borrowed native packet's payload")
            check(clone.pointee.size == 1_048_576 && clone.pointee.data[0] == 37
                && clone.pointee.data[1_048_575] == 83, "borrowed payload was invalidated")
            av_packet_free(&borrowed)
            check(receipt.count == (baseline ? 0 : 1), "payload did not follow the last native owner")
            recovery.reset()
            check(receipt.count == 1, "borrowed payload did not release exactly once")
            controls.append(ControlObservation(name: "borrowed-native-packet", checks: checks - start))
            withExtendedLifetime(recovery) {}
        }

        do {
            let start = checks
            let recovery = VideoRecoveryPacketBuffer()
            let old = try fill(recovery, count: 2, bytes: 1_024, generation: 1)
            drain(recovery) {}
            let next = try fill(recovery, count: 3, bytes: 2_048, generation: 2)
            check(old.allSatisfy { $0.count == 1 }, "new generation retained the old EOF GOP")
            func consumeFreshReplay() {
                let replay = recovery.takeReplayPackets(generation: 2)
                check(replay.count == 3 && replay.first?.isKeyframe == true, "EOF retirement broke fresh recovery")
                withExtendedLifetime(replay) {}
            }
            consumeFreshReplay()
            check(next.allSatisfy { $0.count == 1 }, "fresh GOP leaked")
            controls.append(ControlObservation(name: "fresh-GOP-after-seek", checks: checks - start))
            withExtendedLifetime(recovery) {}
        }

        struct Result: Codable {
            let variant: String
            let ffmpegVersion: String
            let avcodecVersion: UInt32
            let avutilVersion: UInt32
            let checks: Int
            let success: [SuccessObservation]
            let controls: [ControlObservation]
        }
        let result = Result(variant: variant, ffmpegVersion: String(cString: av_version_info()),
                            avcodecVersion: avcodec_version(), avutilVersion: avutil_version(),
                            checks: checks, success: success, controls: controls)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(result), as: UTF8.self))
    }
}
