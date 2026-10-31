import CFFmpeg
import Foundation
import Testing
@testable import IlliquidNativePlayback

@Suite("Software decoder threading")
struct SoftwareDecoderThreadingTests {
    @Test(arguments: [AV_CODEC_ID_H264, AV_CODEC_ID_HEVC, AV_CODEC_ID_VP9])
    func zeroEnablesAutomaticThreading(codecID: AVCodecID) throws {
        let automatic = try open(codecID, threads: 0)
        defer { var context: UnsafeMutablePointer<AVCodecContext>? = automatic; avcodec_free_context(&context) }
        let serial = try open(codecID, threads: 1)
        defer { var context: UnsafeMutablePointer<AVCodecContext>? = serial; avcodec_free_context(&context) }
        #expect(serial.pointee.thread_count == 1)
        #expect(serial.pointee.active_thread_type == 0)
        #expect(automatic.pointee.thread_count >= 1)
        if ProcessInfo.processInfo.activeProcessorCount > 1 {
            #expect(automatic.pointee.thread_count > 1)
            #expect(automatic.pointee.active_thread_type != 0)
        }
    }

    @Test(arguments: [1, 2, 4])
    func explicitLimitIsApplied(threads: Int32) throws {
        let context = try open(AV_CODEC_ID_H264, threads: threads)
        defer { var context: UnsafeMutablePointer<AVCodecContext>? = context; avcodec_free_context(&context) }
        #expect(context.pointee.thread_count == threads)
    }

    private func open(_ codecID: AVCodecID, threads: Int32) throws -> UnsafeMutablePointer<AVCodecContext> {
        var parameters = avcodec_parameters_alloc()
        defer { avcodec_parameters_free(&parameters) }
        let p = try #require(parameters)
        p.pointee.codec_type = AVMEDIA_TYPE_VIDEO
        p.pointee.codec_id = codecID
        p.pointee.width = 1920
        p.pointee.height = 1080
        var context: UnsafeMutablePointer<AVCodecContext>?
        var hardware: Int32 = 0
        let result = illiquid_create_decoder_with_thread_count(p, 0, threads, &context, &hardware)
        #expect(result >= 0)
        #expect(hardware == 0)
        return try #require(context)
    }
}
