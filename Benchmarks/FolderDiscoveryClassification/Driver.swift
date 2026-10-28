import Dispatch
import Foundation
import IlliquidCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@_silgen_name("fd_probe_begin") private func meterBegin()
@_silgen_name("fd_probe_end") private func meterEnd()
@_silgen_name("fd_probe_requests") private func meterRequests() -> UInt64
@_silgen_name("fd_probe_bytes") private func meterBytes() -> UInt64
@_silgen_name("fd_probe_largest") private func meterLargest() -> UInt64
@_silgen_name("fd_probe_available") private func meterAvailable() -> Int32
@_silgen_name("fd_probe_consume") private func consume(_ pointer: UnsafeRawPointer?, _ count: Int) -> UInt64

private struct URLReceipt: Codable {
    let absolute: String
    let relative: String
    let base: String?

    init(_ url: URL) {
        absolute = url.absoluteString
        relative = url.relativeString
        base = url.baseURL?.absoluteString
    }
}

private struct PlaylistReceipt: Encodable {
    let folderURL: URLReceipt
    // Use the production Codable representation, including every date and
    // external subtitle. Separate URL spellings also check representation.
    let items: [FolderPlaylistItem]
    let itemURLs: [URLReceipt]
    let subtitleURLs: [[URLReceipt]]

    init(_ playlist: FolderPlaylist) {
        folderURL = URLReceipt(playlist.folderURL)
        items = playlist.items
        itemURLs = playlist.items.map { URLReceipt($0.url) }
        subtitleURLs = playlist.items.map { $0.externalSubtitleURLs.map(URLReceipt.init) }
    }
}

private struct Measurement: Encodable {
    let mode: String
    let wall_ns: UInt64?
    let cpu_ns: UInt64?
    let allocation_requests: UInt64?
    let requested_bytes: UInt64?
    let largest_request_bytes: UInt64?
    let item_count: Int
    let subtitle_count: Int
    let receipt_bytes: Int
    let before_after_equal: Bool
}

private struct MeterControl: Encodable {
    let array_elements: Int
    let allocation_requests: UInt64
    let requested_bytes: UInt64
    let largest_request_bytes: UInt64
    let checksum: UInt64
}

private func encoded<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
}

private func emit<T: Encodable>(_ value: T) throws {
    FileHandle.standardOutput.write(try encoded(value))
    FileHandle.standardOutput.write(Data([10]))
}

private func processCPU() -> UInt64 {
    var clock = timespec()
    precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &clock) == 0)
    return UInt64(clock.tv_sec) * 1_000_000_000 + UInt64(clock.tv_nsec)
}

@inline(never)
private func controlArray(_ count: Int) -> [UInt8] {
    Array(repeating: 0x5A, count: count)
}

private func checkMeter() throws {
    precondition(meterAvailable() == 1, "Allocation instrumentation is unavailable")
    meterBegin()
    meterEnd()
    let count = 262_144
    let warm = controlArray(count)
    _ = warm.withUnsafeBytes { consume($0.baseAddress, $0.count) }
    meterBegin()
    let array = controlArray(count)
    let checksum = array.withUnsafeBytes { consume($0.baseAddress, $0.count) }
    withExtendedLifetime(array) { meterEnd() }
    precondition(meterRequests() >= 1 && meterBytes() >= UInt64(count)
                 && meterLargest() >= UInt64(count) && meterBytes() < UInt64(2 * count),
                 "The meter did not observe one real Swift array allocation")
    try emit(MeterControl(array_elements: count, allocation_requests: meterRequests(),
        requested_bytes: meterBytes(), largest_request_bytes: meterLargest(), checksum: checksum))
    withExtendedLifetime(warm) {}
}

@main
private enum Main {
    static func main() throws {
        let args = CommandLine.arguments
        if args.count == 2, args[1] == "self-test" {
            try checkMeter()
            return
        }
        guard args.count == 4, ["timing", "memory"].contains(args[1]) else {
            fatalError("Usage: probe self-test | probe timing|memory DIRECTORY RECEIPT_JSON")
        }
        let mode = args[1]
        let input = URL(fileURLWithPath: args[2], isDirectory: true)
        if mode == "memory" {
            precondition(meterAvailable() == 1)
            // Resolve meter symbols and initialize TLS before the warmup.
            meterBegin()
            meterEnd()
        }
        // One untimed full discovery warms the component and filesystem cache.
        // Serializing its complete result is also outside the measured region.
        let before = try encoded(PlaylistReceipt(FolderPlaylistDiscovery.discover(in: input)))
        let playlist: FolderPlaylist
        var wall: UInt64?, cpu: UInt64?
        var requests: UInt64?, bytes: UInt64?, largest: UInt64?
        if mode == "memory" {
            meterBegin()
            playlist = try FolderPlaylistDiscovery.discover(in: input)
            meterEnd()
            requests = meterRequests()
            bytes = meterBytes()
            largest = meterLargest()
        } else {
            precondition(meterAvailable() == 0, "Timing must use the uninstrumented binary")
            let cpuStart = processCPU()
            let wallStart = DispatchTime.now().uptimeNanoseconds
            playlist = try FolderPlaylistDiscovery.discover(in: input)
            wall = DispatchTime.now().uptimeNanoseconds - wallStart
            cpu = processCPU() - cpuStart
        }
        // Keep the input and returned model alive through both clock reads.
        withExtendedLifetime(input) {}
        let after = try encoded(PlaylistReceipt(playlist))
        precondition(before == after, "Complete playlist changed during measurement")
        try after.write(to: URL(fileURLWithPath: args[3]))
        try emit(Measurement(mode: mode, wall_ns: wall, cpu_ns: cpu,
            allocation_requests: requests, requested_bytes: bytes, largest_request_bytes: largest,
            item_count: playlist.items.count,
            subtitle_count: playlist.items.reduce(0) { $0 + $1.externalSubtitleURLs.count },
            receipt_bytes: after.count, before_after_equal: true))
        withExtendedLifetime(playlist) {}
    }
}
