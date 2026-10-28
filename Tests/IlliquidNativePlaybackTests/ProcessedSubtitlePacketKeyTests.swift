import Foundation
import XCTest
@testable import IlliquidNativePlayback

final class ProcessedSubtitlePacketKeyTests: XCTestCase {
    func testOnlyReadOrderIsExcludedFromSemanticIdentity() {
        let body = Data("0,Default,,0,0,0,,A caption with commas, 日本語, and accents é".utf8)
        let original = key(Data("1,".utf8) + body)
        XCTAssertEqual(original, key(Data("99999,".utf8) + body))
        XCTAssertEqual(original.data, body)
        XCTAssertNotEqual(original, key(Data("2,".utf8) + body, start: 11))
        XCTAssertNotEqual(original, key(Data("2,".utf8) + body, duration: 21))
        XCTAssertNotEqual(original, key(Data("2,".utf8) + body + Data([0])))
        XCTAssertEqual(key(Data()).data, Data())
        XCTAssertEqual(key(Data("no delimiter".utf8)).data, Data("no delimiter".utf8))
        XCTAssertEqual(key(Data("first,".utf8)), key(Data("second,".utf8)))
        XCTAssertEqual(key(Data(",payload,rest".utf8)).data, Data("payload,rest".utf8))
    }

    func testPayloadAndSetDecisionsMatchLegacyNormalization() {
        var inputs: [Data] = [Data(), Data([0, 0xff, 0xfe]), Data([44]), Data([44, 0, 44, 0xff])]
        // Exercise both sides of the copy/share boundaries, including malformed
        // prefixes and suffixes that fit Foundation's small-data representation.
        for prefixCount in [0, 1, 30, 31, 32, 33, 255, 4_096] {
            for bodyCount in [0, 1, 14, 15, 63, 64, 65, 256, 4_096] {
                inputs.append(Data(repeating: 57, count: prefixCount)
                    + Data([44]) + Data(repeating: 0xff, count: bodyCount))
            }
        }
        var random = Generator()
        for index in 0..<1_024 {
            let count = Int(random.next() % 513)
            let bytes = (0..<count).map { _ in UInt8(truncatingIfNeeded: random.next() >> 24) }
            let packet = Data(bytes)
            if index.isMultiple(of: 3) {
                let backing = Data(repeating: 7, count: 19) + packet + Data(repeating: 8, count: 23)
                inputs.append(backing[19..<(19 + packet.count)])
            } else {
                inputs.append(packet)
            }
        }

        var current: Set<ProcessedSubtitlePacketKey> = []
        var legacy: Set<LegacyKey> = []
        for (index, packet) in inputs.enumerated() {
            let expected = LegacyKey(packetData: packet)
            let actual = key(packet)
            XCTAssertEqual(actual.data, expected.data, "payload at case \(index)")
            XCTAssertEqual(current.insert(actual).inserted, legacy.insert(expected).inserted,
                           "insertion at case \(index)")

            // Another decode changes ReadOrder but must hit the same Set entry,
            // even when the original fixture had no delimiter or contained NULs.
            let redecoded = Data("123456789,".utf8) + expected.data
            XCTAssertFalse(current.insert(key(redecoded)).inserted, "duplicate at case \(index)")
            XCTAssertFalse(legacy.insert(LegacyKey(packetData: redecoded)).inserted)
        }
        XCTAssertEqual(current.count, legacy.count)
    }

    func testMutatingSourceOrPayloadCopyDoesNotChangeStoredKeys() {
        var source = Data("12,".utf8) + Data(repeating: 65, count: 4_096)
        let original = key(source)
        let stored: Set<ProcessedSubtitlePacketKey> = [original]
        source[source.index(source.startIndex, offsetBy: 3)] = 66
        XCTAssertEqual(original.data.first, 65)
        XCTAssertFalse(stored.contains(key(source)))

        var changedBody = original.data
        changedBody[changedBody.startIndex] = 67
        XCTAssertEqual(original.data.first, 65)
        XCTAssertEqual(stored.first?.data.first, 65)
        XCTAssertNotEqual(changedBody, original.data)
        withExtendedLifetime((original, stored, source, changedBody)) {}
    }

    func testMainAndPiPKeepOneOwnedPayloadUntilTheLastSetReleasesIt() {
        for prefixBytes in [1, 32] {
            for bodyBytes in [64, 4_096] {
                let released = ReleaseProbe()
                var (main, pip) = sharedSets(prefixBytes: prefixBytes, bodyBytes: bodyBytes,
                                             released: released)
                XCTAssertEqual(main.first?.data.count, bodyBytes)
                XCTAssertEqual(main, pip)
                XCTAssertEqual(released.count, 0)
                withExtendedLifetime((main, pip)) {}
                main.removeAll()
                XCTAssertEqual(released.count, 0, "PiP still owns the packet")
                pip.removeAll()
                XCTAssertEqual(released.count, 1, "The final key releases its owned packet")
            }
        }
    }

    func testRejectedDuplicateDoesNotRetainTheSecondPacket() {
        let first = ReleaseProbe()
        let duplicate = ReleaseProbe()
        var retained: Set<ProcessedSubtitlePacketKey> = []
        XCTAssertTrue(insertOwned(prefix: "1,", released: first, into: &retained))
        XCTAssertFalse(insertOwned(prefix: "222,", released: duplicate, into: &retained))
        XCTAssertEqual(first.count, 0)
        XCTAssertEqual(duplicate.count, 1)
        XCTAssertEqual(retained.count, 1)
        withExtendedLifetime(retained) {}
        retained.removeAll()
        XCTAssertEqual(first.count, 1)
    }

    func testPruningAndResetReleaseOnlyTheLastOwnerOfEachPacket() {
        let expired = ReleaseProbe()
        let future = ReleaseProbe()
        var (main, pip) = timelineSets(expired: expired, future: future)
        let deadline = 50_000.0
        main = main.filter {
            Double($0.presentationMilliseconds) + Double($0.durationMilliseconds) >= deadline
        }
        XCTAssertEqual(expired.count, 0, "PiP has not pruned its copy yet")
        pip = pip.filter {
            Double($0.presentationMilliseconds) + Double($0.durationMilliseconds) >= deadline
        }
        XCTAssertEqual(expired.count, 1)
        XCTAssertEqual(future.count, 0)
        XCTAssertEqual(main.count, 1)
        XCTAssertEqual(pip.count, 1)
        withExtendedLifetime((main, pip)) {}
        main.removeAll()
        XCTAssertEqual(future.count, 0)
        pip.removeAll()
        XCTAssertEqual(future.count, 1)
    }

    func testTinyBodiesAndLongPrefixesDoNotKeepTheSourceAllocation() {
        for (prefixBytes, bodyBytes) in [(32, 0), (32, 1), (32, 14), (32, 63),
                                        (33, 64), (65_536, 128)] {
            let released = ReleaseProbe()
            let compact = ownedKey(prefixBytes: prefixBytes, bodyBytes: bodyBytes, released: released)
            XCTAssertEqual(compact.data, Data(repeating: 65, count: bodyBytes))
            XCTAssertEqual(released.count, 1,
                           "prefix=\(prefixBytes), body=\(bodyBytes) must compact")
            withExtendedLifetime(compact) {}
        }
    }

    func testAlreadyOffsetInputIsCompactedBeforeTheKeyEscapes() {
        let released = ReleaseProbe()
        let compact = offsetKey(released: released)
        XCTAssertEqual(compact.data, Data(repeating: 65, count: 256))
        XCTAssertEqual(released.count, 1, "A small sliced input must not pin its large prefix")
        withExtendedLifetime(compact) {}
    }

    private func key(_ data: Data, start: Int64 = 10, duration: Int64 = 20) -> ProcessedSubtitlePacketKey {
        ProcessedSubtitlePacketKey(presentationMilliseconds: start,
                                   durationMilliseconds: duration, packetData: data)
    }

    private struct LegacyKey: Hashable {
        let presentationMilliseconds: Int64 = 10
        let durationMilliseconds: Int64 = 20
        let data: Data

        init(packetData: Data) {
            // Exact normalization expression from SubtitlePipeline before this change.
            data = packetData.firstIndex(of: UInt8(ascii: ",")).map {
                Data(packetData[packetData.index(after: $0)...])
            } ?? packetData
        }
    }

    private struct Generator {
        var state: UInt64 = 0x9e3779b97f4a7c15
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
    }

    private final class ReleaseProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var releases = 0
        var count: Int { lock.withLock { releases } }
        func recordRelease() { lock.withLock { releases += 1 } }
    }

    private func ownedData(_ bytes: [UInt8], released: ReleaseProbe) -> Data {
        precondition(!bytes.isEmpty)
        let storage = UnsafeMutableRawPointer.allocate(byteCount: bytes.count, alignment: 16)
        bytes.withUnsafeBytes { source in
            storage.copyMemory(from: source.baseAddress!, byteCount: source.count)
        }
        return Data(bytesNoCopy: storage, count: bytes.count, deallocator: .custom { pointer, _ in
            pointer.deallocate()
            released.recordRelease()
        })
    }

    @inline(never)
    private func sharedSets(prefixBytes: Int, bodyBytes: Int, released: ReleaseProbe)
        -> (Set<ProcessedSubtitlePacketKey>, Set<ProcessedSubtitlePacketKey>) {
        let packet = ownedData(Array(repeating: 57, count: prefixBytes - 1)
            + [44] + Array(repeating: 65, count: bodyBytes), released: released)
        return ([key(packet)], [key(packet)])
    }

    @inline(never)
    private func insertOwned(prefix: String, released: ReleaseProbe,
                             into keys: inout Set<ProcessedSubtitlePacketKey>) -> Bool {
        let packet = ownedData(Array(prefix.utf8) + Array(repeating: 65, count: 4_096),
                               released: released)
        return keys.insert(key(packet)).inserted
    }

    @inline(never)
    private func timelineSets(expired: ReleaseProbe, future: ReleaseProbe)
        -> (Set<ProcessedSubtitlePacketKey>, Set<ProcessedSubtitlePacketKey>) {
        let old = ownedData(Array("1,".utf8) + Array(repeating: 65, count: 4_096), released: expired)
        let next = ownedData(Array("2,".utf8) + Array(repeating: 66, count: 4_096), released: future)
        return ([key(old, start: 0, duration: 1_000), key(next, start: 100_000, duration: 1_000)],
                [key(old, start: 0, duration: 1_000), key(next, start: 100_000, duration: 1_000)])
    }

    @inline(never)
    private func ownedKey(prefixBytes: Int, bodyBytes: Int, released: ReleaseProbe)
        -> ProcessedSubtitlePacketKey {
        key(ownedData(Array(repeating: 57, count: prefixBytes - 1)
            + [44] + Array(repeating: 65, count: bodyBytes), released: released))
    }

    @inline(never)
    private func offsetKey(released: ReleaseProbe) -> ProcessedSubtitlePacketKey {
        let prefix = Array(repeating: UInt8(7), count: 4_096)
        let body = Array("12,".utf8) + Array(repeating: UInt8(65), count: 256)
        let packet = ownedData(prefix + body + Array(repeating: 8, count: 4_096), released: released)
        return key(packet[prefix.count..<(prefix.count + body.count)])
    }
}
