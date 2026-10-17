#if os(Linux)
import Foundation

// Only the platform boundary is replaced. The production ledger stores these
// objects' identities and owns no pixel data. Swift ARC and the production
// token/attachment deinitializers remain real.
final class CVPixelBuffer: @unchecked Sendable {}
final class CMSampleBuffer {
    var attachment: AnyObject?
}
typealias CFString = String
let kCMAttachmentMode_ShouldNotPropagate = 0

func CMSetAttachment(
    _ sample: CMSampleBuffer, key: CFString, value: AnyObject, attachmentMode: Int
) {
    sample.attachment = value
}

enum PlatformSignpostKind { case event }
let nativeVideoSignpostLog = 0
func os_signpost(
    _ kind: PlatformSignpostKind, log: Int, name: StaticString,
    _ format: StaticString, _ arguments: CVarArg...
) {}
#endif
