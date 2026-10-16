// Diagnostic only: documents existing duplicate-digest accounting and verifies
// unchanged count-cap / promotion-tier behavior with real Foundation I/O.
import Foundation
private func digest(_ i: Int) -> String {
    String(repeating: "0", count: 48) + String(format: "%016x", i)
}
@main struct Main {
    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("illiquid-inventory-edge-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let duplicate = root.appendingPathComponent("duplicate")
        try fm.createDirectory(at: duplicate, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 128).write(to: duplicate.appendingPathComponent("b-\(digest(1)).jpg"))
        try Data(repeating: 2, count: 256).write(to: duplicate.appendingPathComponent("f-\(digest(1)).jpg"))
        let disk = NativeThumbnailDiskCache(directory: duplicate)
        let accounted = await disk.bytes()
        let entries = await disk.testEntryCount()
        let cleared = await disk.clear(epoch: 1)
        let remaining = try fm.contentsOfDirectory(atPath: duplicate.path)
        let overfull = root.appendingPathComponent("overfull")
        try fm.createDirectory(at: overfull, withIntermediateDirectories: true)
        for i in 0..<8256 {
            try Data(repeating: 1, count: 128).write(to: overfull.appendingPathComponent("\(i < 64 ? "f" : "b")-\(digest(i)).jpg"))
        }
        let full = NativeThumbnailDiskCache(directory: overfull)
        let bytes = await full.bytes(), count = await full.testEntryCount()
        precondition(count == 8191 && bytes == 8191 * 128)
        let foregroundSurvivors = try fm.contentsOfDirectory(atPath: overfull.path).filter { $0.hasPrefix("f-") }.count
        precondition(foregroundSurvivors == 64)
        let result: [String: Any] = ["duplicate_physical_bytes":384,"duplicate_accounted_bytes":accounted,
            "duplicate_indexed_entries":entries,"duplicate_clear_success":cleared,"duplicate_remaining_filenames":remaining,
            "overfull_initial_files":8256,"overfull_survivors":count,"foreground_survivors":foregroundSurvivors,
            "new_timing_claim":false,"image_codecs_executed":false]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
    }
}
