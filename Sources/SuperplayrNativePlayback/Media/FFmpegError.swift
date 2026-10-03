import CFFmpeg
import Foundation

struct FFmpegError: Error, LocalizedError, Sendable {
    let operation: String
    let code: Int32

    var isInterrupted: Bool { code == superplayr_averror_exit() }
    var isInvalidData: Bool { code == superplayr_averror_invaliddata() }
    var isTryAgain: Bool { code == superplayr_averror_eagain() }

    var errorDescription: String? {
        var buffer = [CChar](repeating: 0, count: 256)
        av_strerror(code, &buffer, buffer.count)
        return buffer.withUnsafeBufferPointer {
            guard let baseAddress = $0.baseAddress else {
                return "\(operation): FFmpeg error \(code)"
            }
            return "\(operation): \(String(cString: baseAddress))"
        }
    }
}

@inline(__always)
func checkFFmpeg(_ value: Int32, operation: String) throws {
    guard value >= 0 else {
        throw FFmpegError(operation: operation, code: value)
    }
}
