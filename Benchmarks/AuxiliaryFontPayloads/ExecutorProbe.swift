// Appended identically to both complete production source files for measurement.
// Retain the executor's production serialization while inspecting native ownership.
extension FFmpegInputExecutor {
    func waitForBenchmarkOpeningToFinish() {
        queue.sync {}
    }

    func withBenchmarkFormatContext<Result>(
        _ body: (UnsafeMutablePointer<AVFormatContext>) throws -> Result
    ) throws -> Result? {
        try perform(kind: .other) { demuxer in
            try demuxer.withBenchmarkFormatContext(body)
        }
    }
}
