// Appended identically to each generated cache source, never shipped in the app.
// Read-only receipts validate complete resident metadata and image identity.
extension NativeThumbnailCache {
    func evictionReceipt() -> [String] {
        precondition(memoryBytes == images.values.reduce(0) { $0 + $1.bytes })
        precondition(memoryBytes <= preferences.memoryMiB * 1024 * 1024)
        precondition(images.count <= maximumResidentImages)
        precondition(storyboardKeys.isSubset(of: Set(images.keys)))
        precondition(pending == nil && writer == nil)
        var result = [
            "bytes=\(memoryBytes);images=\(images.count);serial=\(serial);budget=\(preferences.memoryMiB)",
            "source=\(storyboardSource ?? "nil");epoch=\(epoch);revision=\(memoryRevision)"
        ]
        result += images.map { key, resident in
            "\(key.path)|\(key.version)|\(key.halfSecond)|\(key.width)x\(key.height)|"
                + "\(resident.bytes)|\(resident.used)|\(resident.background)|"
                + "\(storyboardKeys.contains(key))|\(imageToken(resident.image))"
        }.sorted()
        return result
    }

    // Exercise wraparound and equal-minimum fallback without 2^64 insertions.
    // This is test-only state setup, and runs on both baseline and candidate.
    func setTestSerial(_ value: UInt64) { serial = value }

    func tieTestUseCounters() {
        for key in Array(images.keys) { images[key]!.used = 0 }
    }
}
