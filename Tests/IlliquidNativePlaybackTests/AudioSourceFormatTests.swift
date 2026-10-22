import CFFmpeg
import Foundation
import Testing
@testable import IlliquidNativePlayback

@Suite("Audio source format metadata")
struct AudioSourceFormatTests {
    @Test(arguments: ["mono", "stereo", "5.1", "5.1(side)", "7.1"])
    func repeatedNativeLayoutsMatchFFmpeg(layout: String) throws {
        try withFrame { frame in
            try replaceLayout(frame, with: layout)
            var cache = AudioChannelLayoutNameCache()
            let expected = describe(frame)
            for _ in 0..<32 {
                #expect(cache.name(for: frame) == expected)
            }
        }
    }

    @Test func equalChannelCountsWithDifferentMasksInvalidateTheName() throws {
        try withFrame { frame in
            var cache = AudioChannelLayoutNameCache()
            try replaceLayout(frame, with: "5.1")
            let back = cache.name(for: frame)
            try replaceLayout(frame, with: "5.1(side)")
            let side = cache.name(for: frame)
            #expect(back != side)
            #expect(side == describe(frame))
            try replaceLayout(frame, with: "5.1")
            #expect(cache.name(for: frame) == back)
        }
    }

    @Test func unspecifiedOrderUsesChannelCountAndIgnoresTheUnion() throws {
        try withFrame { frame in
            var cache = AudioChannelLayoutNameCache()
            frame.pointee.ch_layout.order = AV_CHANNEL_ORDER_UNSPEC
            frame.pointee.ch_layout.nb_channels = 2
            frame.pointee.ch_layout.u.mask = UInt64.max
            #expect(cache.name(for: frame) == "2 channels")
            frame.pointee.ch_layout.u.mask = 0
            #expect(cache.name(for: frame) == describe(frame))
            frame.pointee.ch_layout.nb_channels = 6
            #expect(cache.name(for: frame) == "6 channels")
            try replaceLayout(frame, with: "5.1")
            #expect(cache.name(for: frame) == "5.1")
        }
    }

    @Test func changingNativeChannelCountAlsoInvalidatesTheName() throws {
        try withFrame { frame in
            // A named standard mask (such as stereo) is described by its
            // canonical name even when its channel count is inconsistent.
            try replaceLayout(frame, with: "FL+LFE")
            var cache = AudioChannelLayoutNameCache()
            let original = cache.name(for: frame)
            // Unusual layouts still preserve FFmpeg's existing description.
            frame.pointee.ch_layout.nb_channels = 3
            #expect(cache.name(for: frame) == describe(frame))
            #expect(cache.name(for: frame) != original)
        }
    }

    @Test func customNamesAndIDsCanChangeAtTheSameAddress() throws {
        try withFrame { frame in
            try customStereo(frame)
            let map = try #require(frame.pointee.ch_layout.u.map)
            var cache = AudioChannelLayoutNameCache()
            let original = cache.name(for: frame)
            setName("Left", on: map)
            let named = cache.name(for: frame)
            #expect(named == describe(frame))
            #expect(named != original)
            map[0].id = AV_CHAN_FRONT_CENTER
            let remapped = cache.name(for: frame)
            #expect(remapped == describe(frame))
            #expect(remapped != named)
            #expect(frame.pointee.ch_layout.u.map == map)
        }
    }

    @Test func equivalentNativeAndCustomDescriptionsKeepTheSameFormatIdentity() throws {
        try withFrame { frame in
            var cache = AudioChannelLayoutNameCache()
            try replaceLayout(frame, with: "stereo")
            let native = format(layout: cache.name(for: frame))
            av_channel_layout_uninit(&frame.pointee.ch_layout)
            try customStereo(frame)
            let custom = format(layout: cache.name(for: frame))
            #expect(native == custom)
            #expect(custom.channelLayout == "stereo")
            try replaceLayout(frame, with: "5.1(side)")
            #expect(cache.name(for: frame) == describe(frame))
            #expect(native.channelLayout == "stereo")
        }
    }

    @Test func customDescriptionsRetainTheExisting128ByteLimit() throws {
        try withFrame { frame in
            #expect(av_channel_layout_custom_init(&frame.pointee.ch_layout, 16) == 0)
            let map = try #require(frame.pointee.ch_layout.u.map)
            for index in 0..<16 {
                map[index].id = AV_CHAN_UNKNOWN
                setName("ChannelName\(index)", on: map.advanced(by: index))
            }
            var full = [CChar](repeating: 0, count: 1_024)
            let required = illiquid_audio_frame_channel_layout_name(frame, &full, full.count)
            #expect(required > 128)
            var cache = AudioChannelLayoutNameCache()
            let prefix = cache.name(for: frame)
            #expect(prefix == describe(frame))
            #expect(prefix.utf8.count == 127)
            // A change beyond the retained prefix must preserve the old
            // description-based equality decision, even for a custom map.
            setName("ChangedLast", on: map.advanced(by: 15))
            #expect(cache.name(for: frame) == prefix)
            #expect(format(layout: cache.name(for: frame)) == format(layout: prefix))
        }
    }

    @Test func ambisonicAndInvalidOrdersKeepTheFallbackBehavior() throws {
        try withFrame { frame in
            var cache = AudioChannelLayoutNameCache()
            for layout in ["stereo", "ambisonic 1", "ambisonic 2", "mono"] {
                try replaceLayout(frame, with: layout)
                #expect(cache.name(for: frame) == describe(frame))
            }
            av_channel_layout_uninit(&frame.pointee.ch_layout)
            frame.pointee.ch_layout.order = AVChannelOrder(rawValue: 99)
            frame.pointee.ch_layout.nb_channels = 2
            #expect(cache.name(for: frame) == "unknown")
            try replaceLayout(frame, with: "stereo")
            #expect(cache.name(for: frame) == "stereo")
        }
    }

    @Test func cachedStringsOutliveTheirFrames() throws {
        var cache = AudioChannelLayoutNameCache()
        var retained = ""
        try withFrame { frame in
            try replaceLayout(frame, with: "5.1(side)")
            retained = cache.name(for: frame)
        }
        try withFrame { frame in
            try replaceLayout(frame, with: "mono")
            #expect(cache.name(for: frame) == "mono")
        }
        #expect(retained == "5.1(side)")
    }

    @Test func everyFormerSignatureFieldStillDistinguishesFormats() {
        let original = format(layout: "stereo")
        let changed = [
            format(layout: "stereo", rate: 44_100),
            format(layout: "stereo", channels: 6),
            format(layout: "2 channels"),
            format(layout: "stereo", sampleFormat: AV_SAMPLE_FMT_S16),
            format(layout: "stereo", outputChannels: 6),
        ]
        for candidate in changed {
            #expect(original != candidate)
        }
        #expect(original == format(layout: "stereo"))
    }

    private func format(
        layout: String, rate: Int32 = 48_000, channels: Int32 = 2,
        sampleFormat: AVSampleFormat = AV_SAMPLE_FMT_FLT, outputChannels: Int = 2
    ) -> AudioSourceFormat {
        AudioSourceFormat(sampleRate: rate, channelCount: channels,
                          channelLayout: layout, sampleFormat: sampleFormat,
                          outputChannelCount: outputChannels)
    }

    private func describe(_ frame: UnsafePointer<AVFrame>) -> String {
        var buffer = [CChar](repeating: 0, count: 128)
        let result = illiquid_audio_frame_channel_layout_name(frame, &buffer, buffer.count)
        return result >= 0 ? stringFromCStringBuffer(buffer) : "unknown"
    }

    private func withFrame(_ body: (UnsafeMutablePointer<AVFrame>) throws -> Void) throws {
        var allocated = av_frame_alloc()
        defer { av_frame_free(&allocated) }
        try body(try #require(allocated))
    }

    private func replaceLayout(_ frame: UnsafeMutablePointer<AVFrame>, with layout: String) throws {
        av_channel_layout_uninit(&frame.pointee.ch_layout)
        let status = av_channel_layout_from_string(&frame.pointee.ch_layout, layout)
        try #require(status == 0)
    }

    private func customStereo(_ frame: UnsafeMutablePointer<AVFrame>) throws {
        try #require(av_channel_layout_custom_init(&frame.pointee.ch_layout, 2) == 0)
        let map = try #require(frame.pointee.ch_layout.u.map)
        map[0].id = AV_CHAN_FRONT_LEFT
        map[1].id = AV_CHAN_FRONT_RIGHT
    }

    private func setName(_ name: String, on channel: UnsafeMutablePointer<AVChannelCustom>) {
        withUnsafeMutableBytes(of: &channel.pointee.name) { bytes in
            bytes.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in name.utf8.prefix(bytes.count - 1).enumerated() {
                bytes[index] = byte
            }
        }
    }
}
