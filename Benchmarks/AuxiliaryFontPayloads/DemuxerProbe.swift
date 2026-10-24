// Appended identically to both complete production source files for measurement.
// This read-only probe runs only after the allocator measurement has finished.
extension FFmpegDemuxer {
    func withBenchmarkFormatContext<Result>(
        _ body: (UnsafeMutablePointer<AVFormatContext>) throws -> Result
    ) rethrows -> Result? {
        guard let context else { return nil }
        return try body(context)
    }
}
