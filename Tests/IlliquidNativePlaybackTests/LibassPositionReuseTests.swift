import CoreGraphics
import CryptoKit
import Foundation
import Testing
@testable import IlliquidNativePlayback

@Suite("libass position-only mask reuse", .serialized)
struct LibassPositionReuseTests {
    @Test func movingFramesMatchFullCopiesAcrossForwardBackwardAndEmptyQueries() throws {
        let context = try makePositionContext()
        let reference = try makePositionContext()
        var previous: ASSReusableRenderSnapshot?
        var visible: [ASSRenderedRegion] = []
        var positionChanges = 0
        for seconds in [0.5, 1.0, 1.5, 1.5, 2.0, 3.5, 2.5, 0.5, 8.5, 9.0, 1.0] {
            let result = context.render(at: seconds, copyIfUnchanged: false, reusing: previous)
            let expected = reference.render(at: seconds)
            if let regions = result.regions { visible = regions }
            assertPositionRegions(visible, equal: try #require(expected.regions))
            #expect(result.change == expected.change)
            #expect(result.resourceLimitExceeded == expected.resourceLimitExceeded)
            if result.regions != nil {
                #expect(result.imageCount == expected.imageCount)
                #expect(result.maskBytes == expected.maskBytes)
            }
            if result.change == 1 {
                positionChanges += 1
                #expect(result.bitmapCopies == 0)
                #expect(result.imageCount > 0)
            }
            previous = result.reusableSnapshot
        }
        // Fail if the native fixture no longer exercises the intended path.
        #expect(positionChanges > 0)
    }

    @Test func unchangedRenderRetagsTheSnapshotForTheNextMovingFrame() throws {
        let context = try makePositionContext()
        let first = context.render(at: 0.5)
        let initial = try #require(first.reusableSnapshot)
        #expect(first.bitmapCopies > 0)
        let unchanged = context.render(at: 0.5, copyIfUnchanged: false, reusing: initial)
        #expect(unchanged.change == 0)
        #expect(unchanged.regions == nil)
        #expect(unchanged.bitmapCopies == 0)
        let retagged = try #require(unchanged.reusableSnapshot)
        let moved = context.render(at: 1.0, copyIfUnchanged: false, reusing: retagged)
        #expect(moved.change == 1)
        #expect(moved.bitmapCopies == 0)
        let reference = try makePositionContext()
        assertPositionRegions(try #require(moved.regions),
                              equal: try #require(reference.render(at: 1.0).regions))
    }

    @Test(arguments: ["absent", "foreign", "stale"])
    func invalidSnapshotsFallBackToFreshOwnedMasks(kind: String) throws {
        let context = try makePositionContext()
        let reference = try makePositionContext()
        let first = context.render(at: 0.5)
        _ = reference.render(at: 0.5)
        let initial = try #require(first.reusableSnapshot)
        let previous: ASSReusableRenderSnapshot?
        let seconds: Double
        switch kind {
        case "foreign":
            let other = try makePositionContext()
            previous = try #require(other.render(at: 0.5).reusableSnapshot)
            seconds = 1.0
        case "stale":
            _ = context.render(at: 1.0, copyIfUnchanged: false, reusing: initial)
            _ = reference.render(at: 1.0)
            previous = initial
            seconds = 1.5
        default:
            previous = nil
            seconds = 1.0
        }
        let result = context.render(at: seconds, copyIfUnchanged: false, reusing: previous)
        #expect(result.change == 1)
        #expect(result.imageCount > 0)
        #expect(result.bitmapCopies == result.imageCount)
        assertPositionRegions(try #require(result.regions),
                              equal: try #require(reference.render(at: seconds).regions))
    }

    @Test func changingAdmissionLimitsRebuildsTheSameDeterministicSubset() throws {
        let context = try makePositionContext()
        let reference = try makePositionContext()
        var previous: ASSReusableRenderSnapshot?
        let requests: [(seconds: Double, count: Int, bytes: Int, reuse: Bool)] = [
            (0.5, 256, 64 * 1_024 * 1_024, false),
            (1.0, 1, 64 * 1_024 * 1_024, false),
            (1.5, 1, 64 * 1_024 * 1_024, true),
            (2.0, 256, 1, false),
            (2.5, 256, 64 * 1_024 * 1_024, false),
            (3.0, 256, 64 * 1_024 * 1_024, true),
        ]
        for request in requests {
            let result = context.render(
                at: request.seconds, copyIfUnchanged: false,
                maximumImageCount: request.count, maximumBitmapBytes: request.bytes,
                reusing: previous
            )
            let expected = reference.render(
                at: request.seconds, maximumImageCount: request.count,
                maximumBitmapBytes: request.bytes
            )
            assertPositionRegions(try #require(result.regions),
                                  equal: try #require(expected.regions))
            #expect(result.imageCount == expected.imageCount)
            #expect(result.maskBytes == expected.maskBytes)
            #expect(result.resourceLimitExceeded == expected.resourceLimitExceeded)
            #expect(result.bitmapCopies == (request.reuse ? 0 : expected.imageCount))
            if request.count == 1 {
                #expect(result.imageCount == 1)
                #expect(result.resourceLimitExceeded)
            }
            if request.bytes == 1 {
                #expect(result.imageCount == 0)
                #expect(result.resourceLimitExceeded)
            }
            previous = result.reusableSnapshot
        }
    }

    @Test(arguments: [false, true])
    func unchangedFrameWithMissingOrStaleTokenForcesTheNextMoveToCopy(stale: Bool) throws {
        let context = try makePositionContext()
        let reference = try makePositionContext()
        let initial = try #require(context.render(at: 0.5).reusableSnapshot)
        _ = reference.render(at: 0.5)
        if stale {
            _ = context.render(at: 1.0, copyIfUnchanged: false, reusing: initial)
            _ = reference.render(at: 1.0)
        }
        let sameTime = stale ? 1.0 : 0.5
        let unchanged = context.render(at: sameTime, copyIfUnchanged: false,
                                       reusing: stale ? initial : nil)
        _ = reference.render(at: sameTime)
        #expect(unchanged.change == 0)
        #expect(unchanged.regions == nil)
        #expect(unchanged.reusableSnapshot == nil)
        #expect(unchanged.bitmapCopies == 0)
        #expect(unchanged.imageCount == 0)
        #expect(unchanged.maskBytes == 0)
        let nextTime = sameTime + 0.5
        let result = context.render(at: nextTime, copyIfUnchanged: false,
                                    reusing: unchanged.reusableSnapshot)
        #expect(result.change == 1)
        #expect(result.imageCount > 0)
        #expect(result.bitmapCopies == result.imageCount)
        assertPositionRegions(try #require(result.regions),
                              equal: try #require(reference.render(at: nextTime).regions))
    }

    @Test func defaultUnchangedCopyContractRemainsAvailable() throws {
        let context = try makePositionContext()
        let first = context.render(at: 0.5)
        let result = context.render(at: 0.5, reusing: first.reusableSnapshot)
        #expect(result.change == 0)
        #expect(result.imageCount > 0)
        #expect(result.bitmapCopies == result.imageCount)
        assertPositionRegions(try #require(result.regions), equal: try #require(first.regions))
    }

    @Test func unchangedGeometryKeepsTheTokenButChangedGeometryRetiresIt() throws {
        let size = CGSize(width: 1920, height: 1080)
        let context = try makePositionContext()
        let initial = try #require(context.render(at: 0.5).reusableSnapshot)
        #expect(!context.configure(frameSize: size, storageSize: size))
        let moved = context.render(at: 1.0, copyIfUnchanged: false, reusing: initial)
        #expect(moved.change == 1)
        #expect(moved.bitmapCopies == 0)

        let previous = try #require(moved.reusableSnapshot)
        let alternate = CGSize(width: 1280, height: 720)
        #expect(context.configure(frameSize: alternate, storageSize: size))
        #expect(context.configure(frameSize: size, storageSize: size))
        let afterConfiguration = context.render(at: 1.5, copyIfUnchanged: false, reusing: previous)
        #expect(afterConfiguration.imageCount > 0)
        #expect(afterConfiguration.bitmapCopies == afterConfiguration.imageCount)
        let reference = try makePositionContext()
        assertPositionRegions(try #require(afterConfiguration.regions),
                              equal: try #require(reference.render(at: 1.5).regions))
    }

    @Test(arguments: [false, true])
    func resettingOrReplacingTheSourceRetiresOldSnapshots(reset: Bool) throws {
        let context = try makePositionContext()
        let previous = try #require(context.render(at: 0.5).reusableSnapshot)
        if reset { try context.reset() }
        let replacement = positionScript(text: "A different subtitle source")
        try context.loadExternal(data: replacement)
        let result = context.render(at: 1.0, copyIfUnchanged: false, reusing: previous)
        #expect(result.imageCount > 0)
        #expect(result.bitmapCopies == result.imageCount)
        let reference = try makePositionContext(replacement)
        assertPositionRegions(try #require(result.regions),
                              equal: try #require(reference.render(at: 1.0).regions))
    }

    @Test func translatedSnapshotsDoNotTranslateTheNextNativeOutputTwice() throws {
        let context = try makePositionContext()
        let initial = try #require(context.render(at: 0.5).reusableSnapshot)
        let translated = initial.offsetBy(dx: 31, dy: 47).offsetBy(dx: 0, dy: 0)
        for (original, shifted) in zip(initial.regions, translated.regions) {
            #expect(shifted.frame == original.frame.offsetBy(dx: 31, dy: 47))
            #expect(shifted.bitmap == original.bitmap)
        }
        let result = context.render(at: 1.0, copyIfUnchanged: false, reusing: translated)
        #expect(result.change == 1)
        #expect(result.bitmapCopies == 0)
        let reference = try makePositionContext()
        assertPositionRegions(try #require(result.regions),
                              equal: try #require(reference.render(at: 1.0).regions))
    }

    @Test func retainedSnapshotsOwnMasksWithoutKeepingTheNativeContextAlive() throws {
        var context: LibassContext? = try makePositionContext()
        weak var releasedContext = context
        let snapshot = try #require(context!.render(at: 0.5).reusableSnapshot)
        #expect(!snapshot.regions.isEmpty)
        let hashes = snapshot.regions.map { Array(SHA256.hash(data: $0.bitmap)) }
        _ = context!.render(at: 6.0)
        try context!.reset()
        try context!.loadExternal(data: positionScript(text: "Replacement"))
        _ = context!.render(at: 1.0)
        context = nil
        #expect(releasedContext == nil)
        #expect(snapshot.regions.map { Array(SHA256.hash(data: $0.bitmap)) } == hashes)
        withExtendedLifetime(snapshot) {}
    }

    @Test func contentAndEmptyFrameChangesKeepTheFullCopySemantics() throws {
        let source = positionScript(text: #"{\t(0,4000,\fs110)}Changing size"#)
        let context = try makePositionContext(source)
        let reference = try makePositionContext(source)
        var previous: ASSReusableRenderSnapshot?
        var contentChanges = 0
        for seconds in [0.5, 1.0, 2.0, 3.0, 8.5, 1.0] {
            let result = context.render(at: seconds, copyIfUnchanged: false, reusing: previous)
            let expected = reference.render(at: seconds)
            assertPositionRegions(try #require(result.regions),
                                  equal: try #require(expected.regions))
            #expect(result.change == expected.change)
            if result.change == 2 {
                contentChanges += 1
                #expect(result.bitmapCopies == result.imageCount)
            }
            previous = result.reusableSnapshot
        }
        #expect(contentChanges > 0)
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude])
    func invalidQueriesRetirePreviousTokens(seconds: Double) throws {
        let context = try makePositionContext()
        let previous = try #require(context.render(at: 0.5).reusableSnapshot)
        let invalid = context.render(at: seconds, copyIfUnchanged: false, reusing: previous)
        #expect(invalid.regions?.isEmpty == true)
        #expect(invalid.reusableSnapshot == nil)
        let result = context.render(at: 1.0, copyIfUnchanged: false, reusing: previous)
        #expect(result.change == 1)
        #expect(result.imageCount > 0)
        #expect(result.bitmapCopies == result.imageCount)
    }
}

private func makePositionContext(_ data: Data = positionScript()) throws -> LibassContext {
    let context = try LibassContext()
    let size = CGSize(width: 1920, height: 1080)
    #expect(context.configure(frameSize: size, storageSize: size))
    try context.loadExternal(data: data)
    return context
}

private func positionScript(text: String = "Moving masks retain their pixels") -> Data {
    let header = """
    [Script Info]
    ScriptType: v4.00+
    PlayResX: 1920
    PlayResY: 1080
    ScaledBorderAndShadow: yes
    WrapStyle: 2

    [V4+ Styles]
    Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
    Style: Default,Arial,48,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,2,1,7,0,0,0,1

    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text

    """
    // Integer placement changes preserve libass's cached rasterization.
    let event = "Dialogue: 0,0:00:00.00,0:00:08.00,Default,,0,0,0,,{\\an7\\move(100,100,900,100,0,8000)}\(text)\n"
    return Data((header + event).utf8)
}

private func assertPositionRegions(_ actual: [ASSRenderedRegion], equal expected: [ASSRenderedRegion]) {
    #expect(actual.count == expected.count)
    for (left, right) in zip(actual, expected) {
        #expect(left.bitmap == right.bitmap)
        #expect(left.color == right.color)
        #expect(left.frame == right.frame)
        #expect(left.stride == right.stride)
        #expect(left.bitmapSize == right.bitmapSize)
        #expect(left.isPremultipliedBGRA == right.isPremultipliedBGRA)
        #expect((left.memoryLease != nil) == (right.memoryLease != nil))
    }
}
