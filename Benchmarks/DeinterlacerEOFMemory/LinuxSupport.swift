import CFFmpeg

// The Linux component harness exercises software AVFrames only. Keep the
// production hardware guard intact: Linux has no CoreVideo or VideoToolbox,
// so an accidental hardware input must be rejected by that guard, not mocked
// as a successful transfer. All filtering and AVFrame ownership use FFmpeg.
typealias CVReturn = Int32
final class UnavailableCVPixelBuffer {}

func illiquid_videotoolbox_pixel_buffer(
    _ frame: UnsafePointer<AVFrame>?
) -> Unmanaged<UnavailableCVPixelBuffer>? {
    nil
}

func CVPixelBufferGetDataSize(_ buffer: UnavailableCVPixelBuffer) -> Int {
    preconditionFailure("CoreVideo is unavailable in the software-only Linux harness")
}
