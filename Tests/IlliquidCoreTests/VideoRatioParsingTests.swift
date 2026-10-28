import CoreGraphics
import Foundation
import Testing
@testable import IlliquidCore

@Suite("Video aspect/crop ratio parsing")
struct VideoRatioParsingTests {
    @Test func acceptsScalarAndColonFormsWithoutChangingDivision() {
        let cases: [(String, Double)] = [
            ("1", 1), ("1.25", 1.25), ("16:9", 16.0 / 9.0),
            ("4:3", 4.0 / 3.0), ("+1", 1), (".5", 0.5), ("1.", 1),
            ("1e1", 10), ("1E-1", 0.1), ("1e2:1e1", 10),
            ("00016:00009", 16.0 / 9.0), ("0.2:2", 0.1), ("20:2", 10),
        ]
        for (text, expected) in cases {
            #expect(VideoPresentationGeometry.ratio(text)?.bitPattern == expected.bitPattern,
                    "Unexpected ratio bits for \(text)")
        }
    }

    @Test func rejectsEmptyExtraAndNonpositiveFields() {
        #expect(VideoPresentationGeometry.ratio(nil) == nil)
        let inputs = [
            "", ":", "::", "1:", ":1", "1::2", "1:2:3", "1:1:", ":1:1",
            "0", "-0", "-1", "0:1", "1:0", "1:-0", "1:-1", "-1:-1",
            "nan", "NaN:1", "1:nan", "inf", "infinity", "1:inf", "inf:inf",
            "1e309", "1e309:1e309", "1:1e309", "1e-999", "1:1e-999",
            "one", "1/2", "1,5", "1x", "1:2x", "１２:９",
        ]
        for text in inputs {
            #expect(VideoPresentationGeometry.ratio(text) == nil, "Unexpected acceptance of \(text)")
        }
        let manyFields = Array(repeating: "1", count: 2_048).joined(separator: ":")
        #expect(VideoPresentationGeometry.ratio(manyFields) == nil)
    }

    @Test func retainsInclusiveBoundsAndExtremeFiniteOperands() {
        for value in [0.1, 0.1.nextUp, 1.0, 10.0.nextDown, 10.0] {
            #expect(VideoPresentationGeometry.ratio(String(value))?.bitPattern == value.bitPattern)
        }
        for value in [0.1.nextDown, 10.0.nextUp] {
            #expect(VideoPresentationGeometry.ratio(String(value)) == nil)
        }
        for value in [Double.leastNonzeroMagnitude, .leastNormalMagnitude, .greatestFiniteMagnitude] {
            let operand = String(value)
            #expect(VideoPresentationGeometry.ratio("\(operand):\(operand)")?.bitPattern == Double(1).bitPattern)
        }
        let largest = String(Double.greatestFiniteMagnitude)
        let smallest = String(Double.leastNonzeroMagnitude)
        #expect(VideoPresentationGeometry.ratio("\(largest):\(smallest)") == nil)
        #expect(VideoPresentationGeometry.ratio("\(smallest):\(largest)") == nil)
    }

    @Test func preservesDoubleGrammarAndCharacterDelimiterSemantics() {
        // Double's accepted grammar is the contract. Do not replace it with an
        // ASCII-only number parser or add trimming/normalization in this path.
        let operands = [
            "", "0", "1", "2.5", "+1", "-1", "-0", ".5", "1.", "1e0", "1E+1",
            "0x1p0", "0x1.8p+1", "0X1P0", "0x1", "0x1p-4", "nan", "inf", "Infinity",
            " 1", "1 ", "\t1", "1\n", "\r\n1", "1\r\n", "\u{00A0}1", "1\u{2028}",
            "1\u{0}", "1\u{0}2", "١", "１", "1\u{0301}", "1\u{200D}", "😀", "e\u{0301}",
        ]
        for a in operands {
            expectReferenceParity(a)
            for b in operands {
                expectReferenceParity(a + ":" + b)
                expectReferenceParity(a + ":" + b + ":1")
            }
        }
        for text in [
            "1:\u{0301}2", "1:\u{FE0F}2", "1:\u{034F}2", "1\u{0301}:2", "1\u{FF1A}2",
            "1\u{2236}2", "1:\u{200D}2", "1\u{200D}:2", "1\r\n:2", "1:\r\n2",
            "1:2:\u{0301}3", "1:\u{0301}2:3", "1:2\u{0}:3",
            "1:1\u{0}:\u{0301}", "1:1\u{0}:\u{FE0F}", "1:1\u{0}:\u{200D}",
            "1:1\u{0}:\u{0301}:\u{0301}", "1:2\r\n", "1\u{0}:2", "1:\u{0}",
        ] {
            expectReferenceParity(text)
        }
    }

    @Test func seededMixedStringsMatchTheOriginalSplitContract() {
        let tokens = ["0", "1", "2", "9", ".", ":", "e", "E", "x", "p", "+", "-",
                      " ", "\t", "\n", "\u{0}", "\u{0301}", "\u{FE0F}", "\u{200D}", "１", "😀"]
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            return state
        }
        for _ in 0..<2_048 {
            let count = Int(next() % 24)
            var text = ""
            for _ in 0..<count { text += tokens[Int(next() % UInt64(tokens.count))] }
            expectReferenceParity(text)
        }
    }

    @Test func completeGeometryKeepsExpectedCoordinateBits() {
        let source = CGSize(width: 200, height: 100)
        let bounds = CGRect(x: 10, y: 20, width: 120, height: 80)
        struct Case {
            let aspect: String?
            let crop: String?
            let mode: VideoScaleMode?
            let image: CGRect
            let clip: CGRect
        }
        let fitted = CGRect(x: 10, y: 30, width: 120, height: 60)
        let cases: [Case] = [
            .init(aspect: nil, crop: nil, mode: nil, image: fitted, clip: fitted),
            .init(aspect: "2:1", crop: nil, mode: .fit, image: fitted, clip: fitted),
            .init(aspect: "2e0", crop: nil, mode: .fit, image: fitted, clip: fitted),
            .init(aspect: "2:1", crop: nil, mode: .fill,
                  image: CGRect(x: -10, y: 20, width: 160, height: 80), clip: bounds),
            .init(aspect: "2:1", crop: "1:1", mode: .fit,
                  image: CGRect(x: -10, y: 20, width: 160, height: 80),
                  clip: CGRect(x: 30, y: 20, width: 80, height: 80)),
            .init(aspect: "2:1", crop: "1:1", mode: .fill,
                  image: CGRect(x: -50, y: 0, width: 240, height: 120), clip: bounds),
            .init(aspect: "2:1", crop: "4:1", mode: .fit,
                  image: fitted, clip: CGRect(x: 10, y: 45, width: 120, height: 30)),
            .init(aspect: "0:1", crop: "1:0", mode: .fit, image: fitted, clip: fitted),
            .init(aspect: "1:2:3", crop: "", mode: .fit, image: fitted, clip: fitted),
        ]
        for item in cases {
            var adjustments = VideoAdjustmentState(aspectRatio: item.aspect, crop: item.crop)
            adjustments.scaleMode = item.mode
            let geometry = VideoPresentationGeometry(sourceSize: source, bounds: bounds, adjustments: adjustments)
            #expect(rectBits(geometry.imageRect) == rectBits(item.image))
            #expect(rectBits(geometry.clipRect) == rectBits(item.clip))
        }
        for invalidSource in [CGSize.zero, CGSize(width: CGFloat.infinity, height: 100),
                              CGSize(width: 100, height: CGFloat.nan)] {
            let geometry = VideoPresentationGeometry(sourceSize: invalidSource, bounds: bounds,
                                                       adjustments: .init(aspectRatio: "16:9", crop: "1:1"))
            #expect(rectBits(geometry.imageRect) == rectBits(.zero))
            #expect(rectBits(geometry.clipRect) == rectBits(.zero))
        }
    }

    private func expectReferenceParity(_ text: String) {
        #expect(VideoPresentationGeometry.ratio(text)?.bitPattern == originalRatio(text)?.bitPattern,
                "Original split contract changed for \(String(reflecting: text))")
    }

    // Frozen behavioral reference from ea2ff568237e2667f7b1aeee67b11a44ebe95b72.
    private func originalRatio(_ text: String?) -> Double? {
        guard let text else { return nil }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let a = Double(parts[0]), a.isFinite, a > 0 else { return nil }
        let b = parts.count == 2 ? Double(parts[1]) : 1
        guard let b, b.isFinite, b > 0 else { return nil }
        let ratio = a / b
        return (0.1...10).contains(ratio) ? ratio : nil
    }

    private func rectBits(_ rect: CGRect) -> [UInt64] {
        [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height].map { Double($0).bitPattern }
    }
}
