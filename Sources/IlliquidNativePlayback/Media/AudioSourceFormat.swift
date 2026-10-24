import CFFmpeg
import Foundation

/// Resampler identity retains the same fields and layout-description equality
/// as the former formatted string, without formatting a new string per frame.
struct AudioSourceFormat: Equatable {
    let sampleRate: Int32
    let channelCount: Int32
    let channelLayout: String
    let sampleFormat: AVSampleFormat
    let outputChannelCount: Int
}

/// Owns only scalar layout metadata and a Swift string, never frame storage.
/// Custom channel maps can change in place, so they always use FFmpeg's
/// description path, including its existing truncation and error behavior.
struct AudioChannelLayoutNameCache {
    private struct Key: Equatable {
        let order: AVChannelOrder
        let channelCount: Int32
        let mask: UInt64

        init?(_ layout: AVChannelLayout) {
            switch layout.order {
            case AV_CHANNEL_ORDER_NATIVE:
                mask = layout.u.mask
            case AV_CHANNEL_ORDER_UNSPEC:
                // FFmpeg defines the union as unused for unspecified order.
                mask = 0
            default:
                return nil
            }
            order = layout.order
            channelCount = layout.nb_channels
        }
    }

    private var cachedKey: Key?
    private var cachedName: String?

    mutating func name(for frame: UnsafePointer<AVFrame>) -> String {
        let key = Key(frame.pointee.ch_layout)
        if let key, key == cachedKey, let cachedName {
            return cachedName
        }

        var buffer = [CChar](repeating: 0, count: 128)
        let result = illiquid_audio_frame_channel_layout_name(
            frame, &buffer, buffer.count
        )
        let name = result >= 0 ? stringFromCStringBuffer(buffer) : "unknown"
        cachedKey = result >= 0 ? key : nil
        cachedName = cachedKey == nil ? nil : name
        return name
    }
}
