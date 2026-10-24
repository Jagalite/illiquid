import Foundation
import Testing
@testable import IlliquidNativePlayback
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@Suite("Compact libass bitmap copies")
struct ASSBitmapCopyTests {
    @Test func preservesVisiblePixelsAndRowOrderWithoutPadding() throws {
        let layout = try #require(ASSBitmapCopyLayout(width: 3, height: 3, sourceStride: 8))
        #expect(layout.byteCount == 9)
        #expect(layout.sourceByteCount == 19)
        // No final-row padding is present. Earlier padding is deliberately
        // distinct from every visible alpha value.
        let source: [UInt8] = [1, 2, 3, 250, 250, 250, 250, 250,
                               4, 5, 6, 251, 251, 251, 251, 251,
                               7, 8, 9]
        let copied = source.withUnsafeBytes { layout.copy(from: $0.baseAddress!) }
        #expect(copied == Data(1...9))
    }

    @Test func copiedBytesOutliveSourceAndRemainIndependent() throws {
        let layout = try #require(ASSBitmapCopyLayout(width: 17, height: 4, sourceStride: 32))
        let source = UnsafeMutableRawPointer.allocate(byteCount: layout.sourceByteCount, alignment: 1)
        source.initializeMemory(as: UInt8.self, repeating: 0x5A, count: layout.sourceByteCount)
        let copied = layout.copy(from: source)
        source.initializeMemory(as: UInt8.self, repeating: 0, count: layout.sourceByteCount)
        source.deallocate()
        #expect(copied.count == 68)
        #expect(copied.allSatisfy { $0 == 0x5A })
        var changed = copied
        changed[0] = 0xA5
        #expect(copied[0] == 0x5A)
        #expect(changed[0] == 0xA5)
    }

    @Test func tightAndPaddedLayoutsMatchAcrossDimensions() throws {
        for width in [1, 2, 7, 15, 16, 17, 31, 32, 33, 127, 255] {
            for height in [1, 2, 3, 16, 63] {
                let expected = Data((0..<(width * height)).map { UInt8(truncatingIfNeeded: $0 * 13 + 7) })
                for padding in [0, 1, 7, 31, 128] {
                    let layout = try #require(ASSBitmapCopyLayout(
                        width: width, height: height, sourceStride: width + padding
                    ))
                    var source = Data(repeating: 0xE5, count: layout.sourceByteCount)
                    for row in 0..<height {
                        source.replaceSubrange(
                            (row * layout.sourceStride)..<(row * layout.sourceStride + width),
                            with: expected[(row * width)..<((row + 1) * width)]
                        )
                    }
                    let copied = source.withUnsafeBytes { layout.copy(from: $0.baseAddress!) }
                    #expect(copied == expected)
                    #expect(copied.count == width * height)
                }
            }
        }
    }

    @Test func rejectsInvalidGeometryAndEveryOverflowBeforePointerUse() {
        for (width, height, stride) in [
            (0, 1, 1), (1, 0, 1), (-1, 2, 2), (2, -1, 2),
            (1, 1, 0), (2, 1, 1), (1, 1, -1),
            (Int.max, 2, Int.max), // destination multiplication
            (1, 3, Int.max),       // source row-offset multiplication
            (1, 2, Int.max),       // source final-row addition
        ] {
            #expect(ASSBitmapCopyLayout(width: width, height: height, sourceStride: stride) == nil)
        }
        // A huge unused stride does not make a one-row mask invalid.
        let singleRow = ASSBitmapCopyLayout(width: 1, height: 1, sourceStride: Int.max)
        #expect(singleRow?.byteCount == 1)
        #expect(singleRow?.sourceByteCount == 1)
    }

    #if canImport(Darwin) || canImport(Glibc)
    @Test func neverReadsPastUnpaddedFinalRowAtGuardPage() throws {
        let pageSize = Int(sysconf(Int32(_SC_PAGESIZE)))
        #expect(pageSize > 0)
        guard pageSize > 0 else { return }
        guard let allocation = mmap(nil, pageSize * 2, PROT_READ | PROT_WRITE,
                                    MAP_PRIVATE | MAP_ANON, -1, 0),
              allocation != MAP_FAILED else {
            Issue.record("Could not allocate guard-page fixture")
            return
        }
        defer { _ = munmap(allocation, pageSize * 2) }
        guard mprotect(allocation.advanced(by: pageSize), pageSize, PROT_NONE) == 0 else {
            Issue.record("Could not protect final-row guard page")
            return
        }
        for (width, height, stride) in [(13, 3, 64), (19, 1, Int.max), (32, 4, 32)] {
            let layout = try #require(ASSBitmapCopyLayout(width: width, height: height, sourceStride: stride))
            let source = allocation.advanced(by: pageSize - layout.sourceByteCount)
            source.initializeMemory(as: UInt8.self, repeating: 0xE5, count: layout.sourceByteCount)
            var expected = Data()
            for row in 0..<height {
                for column in 0..<width {
                    let value = UInt8(truncatingIfNeeded: row * 71 + column)
                    source.storeBytes(of: value, toByteOffset: row * stride + column, as: UInt8.self)
                    expected.append(value)
                }
            }
            #expect(layout.copy(from: source) == expected)
        }
    }
    #endif

    #if canImport(CLibass)
    @Test func nativeRenderChargesCompactBytesAndKeepsAdmissionPassesConsistent() throws {
        let context = try LibassContext()
        #expect(context.configure(frameSize: CGSize(width: 640, height: 360),
                                  storageSize: CGSize(width: 640, height: 360)))
        try context.loadExternal(data: Data(Self.assDocument.utf8))
        let full = context.render(at: 0.5)
        let fullRegions = try #require(full.regions)
        try #require(!fullRegions.isEmpty)
        #expect(!full.resourceLimitExceeded)
        #expect(fullRegions.allSatisfy {
            $0.stride == Int($0.frame.width)
                && $0.bitmap.count == Int($0.frame.width) * Int($0.frame.height)
        })
        let compactBytes = fullRegions.reduce(0) { $0 + $1.bitmap.count }
        #expect(full.maskBytes == compactBytes)
        let unchanged = context.render(at: 0.5, copyIfUnchanged: false)
        #expect(unchanged.regions == nil)
        #expect(unchanged.change == 0)
        #expect(unchanged.bitmapCopies == 0)
        #expect(unchanged.maskBytes == 0)
        let exactFit = context.render(at: 0.5, maximumBitmapBytes: compactBytes)
        #expect(!exactFit.resourceLimitExceeded)
        #expect(exactFit.regions?.map(\.bitmap) == fullRegions.map(\.bitmap))

        // Reintroduce poisoned row padding without changing any visible pixels.
        // Both production CPU packer routes must produce identical output from
        // either representation, including placement and alpha composition.
        let padded = fullRegions.map { region in
            let width = Int(region.frame.width), height = Int(region.frame.height)
            let stride = width + 31
            var bytes = Data(repeating: 0xE5, count: stride * height)
            for row in 0..<height {
                bytes.replaceSubrange(
                    (row * stride)..<(row * stride + width),
                    with: region.bitmap[(row * width)..<((row + 1) * width)]
                )
            }
            return ASSRenderedRegion(bitmap: bytes, color: region.color,
                                     frame: region.frame, stride: stride)
        }
        for strategy in [SubtitleCompositionStrategy.metalR8Atlas, .metalBGRA] {
            let compactFrame = try #require(ASSSubtitleFramePacker().prepare(
                regions: fullRegions, canvasSize: CGSize(width: 640, height: 360), strategy: strategy
            ))
            let paddedFrame = try #require(ASSSubtitleFramePacker().prepare(
                regions: padded, canvasSize: CGSize(width: 640, height: 360), strategy: strategy
            ))
            #expect(compactFrame.pixels == paddedFrame.pixels)
            #expect(compactFrame.quads == paddedFrame.quads)
            #expect(compactFrame.textureSize == paddedFrame.textureSize)
            #expect(compactFrame.bytesPerRow == paddedFrame.bytesPerRow)
        }

        for byteLimit in [0, max(0, compactBytes / 2), max(0, compactBytes - 1)] {
            for imageLimit in [0, 1, fullRegions.count] {
                var expected: [ASSRenderedRegion] = []
                var expectedBytes = 0
                for region in fullRegions where expected.count < imageLimit {
                    if region.bitmap.count <= byteLimit - expectedBytes {
                        expected.append(region)
                        expectedBytes += region.bitmap.count
                    }
                }
                let limited = context.render(at: 0.5, maximumImageCount: imageLimit,
                                             maximumBitmapBytes: byteLimit)
                #expect(limited.resourceLimitExceeded)
                #expect(limited.maskBytes == expectedBytes)
                #expect(limited.imageCount == expected.count)
                #expect(limited.regions?.map(\.bitmap) == expected.map(\.bitmap))
                #expect(limited.regions?.map(\.frame) == expected.map(\.frame))
                #expect(limited.regions?.map(\.color) == expected.map(\.color))
            }
        }
    }

    private static let assDocument = """
    [Script Info]
    ScriptType: v4.00+
    PlayResX: 640
    PlayResY: 360
    [V4+ Styles]
    Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
    Style: Default,Arial,29,&H00FFFFFF,&H000000FF,&H00000000,&H40000000,0,0,0,0,100,100,0,0,1,2,1,2,20,20,20,1
    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
    Dialogue: 0,0:00:00.00,0:00:02.00,Default,,0,0,0,,Compact masks: W i M j
    """
    #endif
}
