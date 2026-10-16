// Timed inventory executes exact disk actor code with actual Foundation directory
// enumeration/stat/trim. No image codec is used in the inventory interval.
import Foundation
#if ALLOCATION_METER
@_silgen_name("meter_begin") func meterBegin()
@_silgen_name("meter_end") func meterEnd()
@_silgen_name("meter_requests") func meterRequests() -> UInt64
@_silgen_name("meter_bytes") func meterBytes() -> UInt64
#endif

private func digest(_ i: Int) -> String { String(repeating: "0", count: 48) + String(format: "%016x", i) }
private func directory() throws -> URL {
    let p = FileManager.default.temporaryDirectory.appendingPathComponent("illiquid-v3-inventory-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: p, withIntermediateDirectories: true)
    return p
}
private func create(_ dir: URL, name: String, data: Data = Data(repeating: 1, count: 128)) throws {
    try data.write(to: dir.appendingPathComponent(name))
}
private func currentRSS() -> Int {
    #if os(Linux)
    guard let text = try? String(contentsOfFile: "/proc/self/status", encoding: .utf8),
          let line = text.split(separator: "\n").first(where: { $0.hasPrefix("VmRSS:") }),
          let value = Int(line.split(whereSeparator: { $0.isWhitespace })[1]) else { return -1 }
    return value * 1024
    #else
    return -1 // macOS footprint must be measured separately with native tooling.
    #endif
}
@main struct Main {
    static func main() async throws {
        if CommandLine.arguments[1] == "tests" { try await tests(); return }
        let count = Int(CommandLine.arguments[1])!, mode = CommandLine.arguments[2]
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        var valid = 0
        for i in 0..<count {
            let name: String
            switch mode {
            case "valid": name = "b-\(digest(i)).jpg"; valid += 1
            case "mixed" where i.isMultiple(of: 10): name = "b-\(digest(i)).jpg"; valid += 1
            case "unrelated": name = "unrelated-\(i).txt"
            default: name = "b-\(String(repeating: "z", count: 48))\(String(format: "%016x", i)).jpg"
            }
            try create(dir, name: name)
        }
        // Warm time infrastructure, not inventory. Fixture creation is excluded.
        let disk = NativeThumbnailDiskCache(directory: dir)
        let rssBefore = currentRSS()
        _ = DispatchTime.now().uptimeNanoseconds
        let start = DispatchTime.now().uptimeNanoseconds
        #if ALLOCATION_METER
        meterBegin()
        #endif
        let bytes = await disk.bytes()
        #if ALLOCATION_METER
        meterEnd()
        #endif
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        let rssAfter = currentRSS()
        let entries = await disk.testEntryCount()
        precondition(entries == min(8191,valid)); precondition(bytes == entries * 128)
        var row: [String: Any] = ["count":count,"mode":mode,"inventory_ns":elapsed,"indexed_entries":entries,
            "indexed_bytes":bytes,"rss_before":rssBefore,"rss_after":rssAfter]
        #if ALLOCATION_METER
        row["allocation_requests"] = meterRequests(); row["allocation_request_bytes"] = meterBytes()
        #endif
        print(String(decoding: try JSONSerialization.data(withJSONObject:row,options:[.sortedKeys]),as:UTF8.self))
    }
    static func tests() async throws {
        var checks = 0
        func expect(_ condition: Bool) { precondition(condition); checks += 1 }
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let good = "f-\(digest(1)).jpg"
        try create(dir, name:good)
        let fakeDirectory = dir.appendingPathComponent("b-\(digest(2)).jpg",isDirectory:true)
        try FileManager.default.createDirectory(at:fakeDirectory,withIntermediateDirectories:true)
        try create(fakeDirectory,name:"must-survive.txt")
        let target = dir.appendingPathComponent("outside-owned-entry.txt")
        try Data("outside".utf8).write(to:target)
        let link = dir.appendingPathComponent("f-\(digest(3)).jpg")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:target)
        let nested = dir.appendingPathComponent("nested",isDirectory:true)
        try FileManager.default.createDirectory(at:nested,withIntermediateDirectories:true)
        try create(nested,name:"b-\(digest(4)).jpg")
        for name in ["b-123.jpg","b-\(String(repeating:"z",count:64)).jpg","F-\(digest(5)).jpg","f-\(digest(6)).JPG","f-\(String(repeating:"Ａ",count:64)).jpg"] {
            try create(dir,name:name)
        }
        let disk = NativeThumbnailDiskCache(directory:dir)
        let bytes = await disk.bytes()
        let entries = await disk.testEntryCount()
        let cleared = await disk.clear(epoch:1)
        let directorySurvives = FileManager.default.fileExists(atPath:fakeDirectory.appendingPathComponent("must-survive.txt").path)
        let symlinkSurvives = (try? FileManager.default.destinationOfSymbolicLink(atPath:link.path)) != nil
        #if CANDIDATE
        expect(entries == 1); expect(bytes == 128); expect(directorySurvives); expect(symlinkSurvives)
        #endif
        expect(cleared)
        expect(!FileManager.default.fileExists(atPath:dir.appendingPathComponent(good).path))
        expect(FileManager.default.fileExists(atPath:target.path))
        expect(FileManager.default.fileExists(atPath:nested.appendingPathComponent("b-\(digest(4)).jpg").path))
        expect(FileManager.default.fileExists(atPath:dir.appendingPathComponent("b-123.jpg").path))
        // Shallow inventory / exact accounting / zero-budget clearing.
        let validDir = try directory(); defer { try? FileManager.default.removeItem(at:validDir) }
        for i in 0..<200 { try create(validDir,name:"\(i.isMultiple(of:2) ? "f" : "b")-\(digest(i)).jpg") }
        let full = NativeThumbnailDiskCache(directory:validDir)
        expect(await full.bytes() == 25_600)
        var settings = ThumbnailPreferences(); settings.diskMiB = 0
        await full.configure(settings)
        expect(await full.bytes() == 0); expect(await full.testEntryCount() == 0)
        // A known image replaced by a directory after inventory must not be
        // recursively removed. POSIX unlink refuses it without a TOCTOU stat check.
        let replacementDir = try directory(); defer { try? FileManager.default.removeItem(at:replacementDir) }
        let cachedPath = replacementDir.appendingPathComponent("b-\(digest(99)).jpg")
        try create(replacementDir,name:cachedPath.lastPathComponent)
        let replacing = NativeThumbnailDiskCache(directory:replacementDir)
        expect(await replacing.bytes() == 128)
        try FileManager.default.removeItem(at:cachedPath)
        try FileManager.default.createDirectory(at:cachedPath,withIntermediateDirectories:true)
        try create(cachedPath,name:"late-sentinel.txt")
        let lateClear = await replacing.clear(epoch:1)
        let lateSurvives = FileManager.default.fileExists(atPath:cachedPath.appendingPathComponent("late-sentinel.txt").path)
        #if CANDIDATE
        expect(!lateClear); expect(lateSurvives)
        #endif
        // Valid filename contract parity over all single-byte substitutions.
        #if CANDIDATE
        var name = Array("b-\(digest(123)).jpg".utf8)
        for offset in [0,1,2,33,65,66,67,68,69] {
            let original = name[offset]
            for value in UInt8.min...UInt8.max {
                name[offset] = value
                let text = String(decoding:name,as:UTF8.self)
                let result = await disk.testParseFilename(text)
                let accepted: Bool
                switch offset {
                case 0: accepted = value == 98 || value == 102
                case 1: accepted = value == 45
                case 2,33,65: accepted = (48...57).contains(value) || (65...70).contains(value) || (97...102).contains(value)
                default: accepted = value == original
                }
                expect((result != nil) == accepted)
            }
            name[offset] = original
        }
        #endif
        let out: [String: Any] = ["checks":checks,"initial_entries":entries,"directory_survived_clear":directorySurvives,
            "symlink_survived_clear":symlinkSurvives,"late_directory_survived_clear":lateSurvives,"late_clear_success":lateClear,"image_codecs_executed":false]
        print(String(decoding:try JSONSerialization.data(withJSONObject:out,options:[.sortedKeys]),as:UTF8.self))
    }
}
