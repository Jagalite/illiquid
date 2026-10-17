import Foundation
import CFFmpeg
#if !PLAYBACK_RESEARCH_STANDALONE
import Testing
@testable import IlliquidNativePlayback
#endif

private final class BufferCheckBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func read() -> Value { lock.withLock { value } }
    func update(_ body: (inout Value) -> Void) { lock.withLock { body(&value) } }
}

private struct BufferCheckReport: Codable {
    var checks = 0
    var failures: [String] = []
    var invalidationTrials = 0
    var replacementRefills = 0
    var staleProducerTimeouts = 0
    mutating func check(_ value: Bool, _ name: String) {
        checks += 1
        if !value { failures.append(name) }
    }
}

private enum PlaybackBufferChecks {
    static func queue(trials: Int, timeout: TimeInterval) -> BufferCheckReport {
        var r = BufferCheckReport()
        // Only public queue methods coordinate this reachable interleaving.
        // The deadline detects unwanted capacity dependence, not a latency SLA.
        for first in [false, true] {
            for budget in 0..<3 {
                for trial in 0..<trials {
                    let q = BoundedQueue<Int>(capacity: budget == 0 ? 1 : 96,
                        byteCapacity: budget == 1 ? 8 : .max,
                        durationCapacityMicroseconds: budget == 2 ? 8 : .max,
                        cost: { _ in BoundedQueueCost(bytes: 8, durationMicroseconds: 8) })
                    r.check(q.push(10), "initial enqueue")
                    let result = BufferCheckBox<Bool?>(nil)
                    let finished = DispatchSemaphore(value: 0)
                    Thread.detachNewThread {
                        let accepted = first ? q.pushFirst(20) : q.push(20)
                        result.update { $0 = accepted }
                        finished.signal()
                    }
                    let blocked = q.waitForBlockedProducer(timeout: 2)
                    r.check(blocked, "producer entered backpressure")
                    q.removeAll()
                    let refilled = q.tryPush(30) == .pushed
                    r.invalidationTrials += 1
                    if refilled { r.replacementRefills += 1 }
                    r.check(refilled, "replacement accepted")
                    let completed = finished.wait(timeout: .now() + timeout) == .success
                    if !completed { r.staleProducerTimeouts += 1 }
                    r.check(completed, "invalidated producer still waiting: first=\(first),budget=\(budget),trial=\(trial)")
                    if completed { r.check(result.read() == false, "stale work rejected") }
                    let budgetState = q.budgetSnapshot
                    r.check(budgetState.items == 1 && budgetState.bytes == 8 && budgetState.durationMicroseconds == 8,
                            "only replacement remains accounted")
                    // Always release blocked threads even when diagnosing the baseline.
                    q.close()
                    if !completed {
                        r.check(finished.wait(timeout: .now() + 2) == .success, "cleanup joined producer")
                        r.check(result.read() == false, "close rejects stale work")
                    }
                }
            }
        }
        do {
            let q = BoundedQueue<Int>(capacity: 2, byteCapacity: 10, cost: { .init(bytes: $0) })
            r.check(q.tryPush(11) == .pushed, "oversized singleton exception preserved")
            r.check(q.tryPush(1) == .wouldBlock, "oversized singleton blocks follower")
            if case .value(let value) = q.pop() { r.check(value == 11, "oversized payload preserved") }
            else { r.check(false, "oversized pop") }
            r.check(q.budgetSnapshot.bytes == 0, "oversized accounting cleared")
            q.close(); r.check(q.tryPush(1) == .closed && !q.push(1) && !q.pushFirst(1), "closed rejects pushes")
        }
        do {
            let q = BoundedQueue<Int>(capacity: 8)
            var model: [Int] = []
            var seed: UInt64 = 0xABCDEF
            for i in 0..<10_000 {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                switch (seed >> 32) % 5 {
                case 0:
                    let got = q.tryPush(i)
                    let expected: BoundedQueuePushResult = model.count < 8 ? .pushed : .wouldBlock
                    r.check(got == expected, "nonblocking admission \(i)")
                    if got == .pushed { model.append(i) }
                case 1 where model.count < 8:
                    r.check(q.pushFirst(i), "prepend \(i)"); model.insert(i, at: 0)
                case 2 where !model.isEmpty:
                    let expected = model.removeFirst()
                    if case .value(let got) = q.pop() { r.check(got == expected, "FIFO/prepend ordering \(i)") }
                    else { r.check(false, "unexpected closed") }
                case 3: q.removeAll(); model.removeAll()
                default: break
                }
                r.check(q.count == model.count, "model occupancy \(i)")
            }
            q.close()
        }
        do {
            let q = BoundedQueue<Int>(capacity: 12)
            let producers = DispatchGroup()
            let consumer = DispatchSemaphore(value: 0)
            let values = BufferCheckBox<[Int]>([])
            for p in 0..<4 {
                producers.enter()
                Thread.detachNewThread {
                    defer { producers.leave() }
                    for i in 0..<2_000 { if !q.push(p * 2_000 + i) { return } }
                }
            }
            Thread.detachNewThread {
                var received: [Int] = []
                for _ in 0..<8_000 {
                    if case .value(let value) = q.pop() { received.append(value) }
                    else { break }
                }
                values.update { $0 = received }; consumer.signal()
            }
            let done = consumer.wait(timeout: .now() + 10) == .success
            if !done { q.close() }
            r.check(done, "concurrent consumer completed")
            r.check(producers.wait(timeout: .now() + 10) == .success, "concurrent producers completed")
            let all = values.read()
            r.check(all.count == 8_000 && Set(all).count == 8_000, "no concurrent loss/duplicates")
            for p in 0..<4 {
                r.check(all.filter { $0 / 2_000 == p } == Array((p * 2_000)..<((p + 1) * 2_000)),
                        "per-producer FIFO \(p)")
            }
            q.close()
        }
        do {
            let q = BoundedQueue<Int>(capacity: 1)
            let ended = DispatchSemaphore(value: 0)
            let closed = BufferCheckBox(false)
            Thread.detachNewThread {
                if case .closed = q.pop() { closed.update { $0 = true } }
                ended.signal()
            }
            q.close()
            r.check(ended.wait(timeout: .now() + 2) == .success && closed.read(), "close releases empty consumer")
        }
        return r
    }

    static func makePacket(bytes: Int, keyframe: Bool, generation: Int = 1, pts: Int64 = 0) throws -> FFmpegPacket {
        guard let p = av_packet_alloc() else { throw FFmpegError(operation: "test allocate packet", code: -12) }
        defer { var pointer: UnsafeMutablePointer<AVPacket>? = p; av_packet_free(&pointer) }
        try checkFFmpeg(av_new_packet(p, Int32(bytes)), operation: "test allocate payload")
        p.pointee.stream_index = 0; p.pointee.pts = pts; p.pointee.dts = pts
        p.pointee.duration = 1; p.pointee.flags = keyframe ? AV_PKT_FLAG_KEY : 0
        return try FFmpegPacket(moving: p, timeBase: .init(num: 1, den: 30), generation: generation)
    }

    static func recovery() throws -> BufferCheckReport {
        var r = BufferCheckReport()
        let limit = VideoRecoveryPacketBuffer.maximumByteCount
        do {
            let b = VideoRecoveryPacketBuffer()
            weak var weakOversized: FFmpegPacket?
            do {
                let packet = try makePacket(bytes: limit + 1, keyframe: true)
                weakOversized = packet; b.record(packet)
            }
            r.check(weakOversized == nil, "oversized initial keyframe is not retained")
            r.check(b.takeReplayPackets(generation: 1).isEmpty, "oversized initial returns no replay")
        }
        do {
            let b = VideoRecoveryPacketBuffer()
            b.record(try makePacket(bytes: 16, keyframe: true))
            b.record(try makePacket(bytes: limit + 1, keyframe: true))
            r.check(b.takeReplayPackets(generation: 1).isEmpty, "oversized replacement invalidates previous GOP")
            b.record(try makePacket(bytes: 32, keyframe: true))
            r.check(b.takeReplayPackets(generation: 1).count == 1, "valid keyframe restores replayability")
        }
        do {
            let b = VideoRecoveryPacketBuffer()
            b.record(try makePacket(bytes: limit, keyframe: true))
            let replay = b.takeReplayPackets(generation: 1)
            r.check(replay.count == 1 && replay[0].byteCount == limit, "exact byte limit accepted")
            r.check(b.takeReplayPackets(generation: 1).isEmpty, "take transfers replay once")
            b.record(try makePacket(bytes: 1, keyframe: true))
            b.record(try makePacket(bytes: limit, keyframe: false))
            r.check(b.takeReplayPackets(generation: 1).isEmpty, "cumulative byte overflow invalidates GOP")
        }
        for count in [512, 513] {
            let b = VideoRecoveryPacketBuffer()
            b.record(try makePacket(bytes: 16, keyframe: true))
            for i in 1..<count { b.record(try makePacket(bytes: 1, keyframe: false, pts: Int64(i))) }
            let replay = b.takeReplayPackets(generation: 1)
            r.check(replay.count == (count == 512 ? 512 : 0), "packet count boundary \(count)")
            if count == 512 { r.check(replay.map(\.presentationTimestamp) == Array(0..<512).map(Int64.init), "replay ordering") }
        }
        do {
            let b = VideoRecoveryPacketBuffer()
            weak var released: FFmpegPacket?
            do { let p = try makePacket(bytes: 32, keyframe: true); released = p; b.record(p) }
            r.check(released != nil, "valid recovery owns its packet")
            b.record(try makePacket(bytes: 1, keyframe: false, generation: 2))
            r.check(released == nil && b.takeReplayPackets(generation: 2).isEmpty, "generation change releases old owner")
        }
        do {
            let b = VideoRecoveryPacketBuffer()
            var model: [FFmpegPacket] = []
            var gen: Int? = nil
            var seed: UInt64 = 0xCAFE
            // Packets are real FFmpeg allocations. The model uses identity and
            // the documented whole-GOP policy, not candidate implementation code.
            var pool: [FFmpegPacket] = []
            for i in 0..<40 {
                let bytes = i % 5 == 0 ? 4096 : i
                let p = try makePacket(bytes: bytes, keyframe: i % 7 == 0,
                                       generation: i % 3, pts: Int64(i))
                pool.append(p)
            }
            for i in 0..<10_000 {
                seed = seed &* 2862933555777941757 &+ 3037000493
                let op = Int((seed >> 32) % 13)
                if op < 10 {
                    let p = pool[Int(seed % 40)]
                    if gen != p.generation { gen = p.generation; model.removeAll() }
                    if p.isKeyframe { model = p.byteCount <= limit ? [p] : [] }
                    else if !model.isEmpty {
                        model.append(p)
                        if model.count > 512 || model.reduce(0, { $0 + $1.byteCount }) > limit { model.removeAll() }
                    }
                    b.record(p)
                } else if op == 10 {
                    b.reset(); model.removeAll(); gen = nil
                } else {
                    let expectedGeneration = Int(seed % 3)
                    let expected = gen == expectedGeneration ? model : []
                    let got = b.takeReplayPackets(generation: expectedGeneration)
                    r.check(got.map(ObjectIdentifier.init) == expected.map(ObjectIdentifier.init), "model replay \(i)")
                    r.check(got.count <= 512 && got.reduce(0, { $0 + $1.byteCount }) <= limit, "replay bounds \(i)")
                    model.removeAll(); gen = expectedGeneration
                }
            }
        }
        return r
    }
}

#if PLAYBACK_RESEARCH_STANDALONE
@main private struct BufferChecksMain {
    static func main() throws {
        #if os(Linux)
        precondition(avcodec_version() >> 16 == 61, "Laboratory ABI requires libavcodec 61")
        #endif
        let trials = Int(CommandLine.arguments.dropFirst().first ?? "32")!
        let report = ["queue":PlaybackBufferChecks.queue(trials: trials, timeout: 0.020),
                      "recovery":try PlaybackBufferChecks.recovery()]
        print(String(decoding:try JSONEncoder().encode(report),as:UTF8.self))
    }
}
#else
@Suite("Playback buffer invalidation and recovery bounds")
struct PlaybackBufferRegressionTests {
    @Test func invalidatedProducersAndQueueContracts() {
        let report = PlaybackBufferChecks.queue(trials: 16, timeout: 1)
        #expect(report.failures.isEmpty, "\(report.failures)")
    }
    @Test func recoveryBoundsAndOwnership() throws {
        let report = try PlaybackBufferChecks.recovery()
        #expect(report.failures.isEmpty, "\(report.failures)")
    }
}
#endif
