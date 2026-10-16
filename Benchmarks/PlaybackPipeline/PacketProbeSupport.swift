import CFFmpeg
import Foundation
// Adapter support: only the Foundation-only members used by FFmpegPacket.
struct FFmpegError: Error { let operation: String; let code: Int32 }
struct FFmpegRational: Equatable, Sendable {
 let numerator: Int32; let denominator: Int32
 init(_ v: AVRational) { numerator=v.num; denominator=v.den }
 var isValid: Bool { numerator != 0 && denominator > 0 }
}
enum MediaTime {
 static func seconds(_ timestamp: Int64, timeBase: FFmpegRational) -> Double {
  guard timestamp != Int64.min, timeBase.isValid else { return 0 }
  return Double(timestamp) * Double(timeBase.numerator) / Double(timeBase.denominator)
 }
}
struct BoundedQueueCost: Equatable, Sendable {
 var bytes: Int; var durationMicroseconds: Int64
 init(bytes: Int=0, durationMicroseconds: Int64=0) {
  self.bytes=max(bytes,0);self.durationMicroseconds=max(durationMicroseconds,0)
 }
}
