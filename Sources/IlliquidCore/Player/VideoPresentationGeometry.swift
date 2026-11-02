import Foundation
import CoreGraphics

public enum VideoScaleMode: String, Codable, CaseIterable, Sendable {
    case fit, fill
}

/// Display-space geometry, after the source's pixel aspect and orientation.
/// Crop changes the visible area; aspect override changes the image shape.
public struct VideoPresentationGeometry: Equatable, Sendable {
    public let imageRect: CGRect
    public let clipRect: CGRect

    public static func ratio(_ text: String?) -> Double? {
        guard let text else { return nil }
        let numerator: Substring
        let denominator: Substring?
        let bytes = text.utf8
        if bytes.allSatisfy({ $0 < 0x80 }) {
            // ASCII colons are complete Characters, so their UTF-8 indices can
            // delimit borrowed numeric fields without a split-result array.
            if let colon = bytes.firstIndex(of: 0x3A) {
                let start = bytes.index(after: colon)
                guard !bytes[start...].contains(0x3A) else { return nil }
                numerator = text[..<colon]
                denominator = text[start...]
            } else {
                numerator = text[...]
                denominator = nil
            }
        } else {
            // Keep Character delimiter semantics for non-ASCII text: a colon
            // followed by a combining mark may be part of a larger grapheme.
            let parts = text.split(separator: ":", omittingEmptySubsequences: false)
            guard (1...2).contains(parts.count) else { return nil }
            numerator = parts[0]
            denominator = parts.count == 2 ? parts[1] : nil
        }
        guard let a = Double(numerator), a.isFinite, a > 0 else { return nil }
        let b: Double?
        if let denominator {
            b = Double(denominator)
        } else {
            b = 1
        }
        guard let b, b.isFinite, b > 0 else { return nil }
        let ratio = a / b
        return (0.1...10).contains(ratio) ? ratio : nil
    }

    public init(sourceSize: CGSize, bounds: CGRect, adjustments: VideoAdjustmentState = .standard) {
        guard sourceSize.width.isFinite, sourceSize.height.isFinite,
              sourceSize.width > 0, sourceSize.height > 0,
              bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0, bounds.height > 0 else {
            imageRect = .zero; clipRect = .zero; return
        }
        let aspect = Self.ratio(adjustments.aspectRatio) ?? sourceSize.width / sourceSize.height
        let imageSize = CGSize(width: aspect, height: 1)
        var cropSize = imageSize
        if let crop = Self.ratio(adjustments.crop) {
            if crop < aspect { cropSize.width = crop }
            else { cropSize.height = aspect / crop }
        }
        let ratios = (bounds.width / cropSize.width, bounds.height / cropSize.height)
        let scale = adjustments.scaleMode == .fill ? max(ratios.0, ratios.1) : min(ratios.0, ratios.1)
        func centered(_ size: CGSize) -> CGRect {
            CGRect(x: bounds.midX - size.width * scale / 2,
                   y: bounds.midY - size.height * scale / 2,
                   width: size.width * scale, height: size.height * scale)
        }
        imageRect = centered(imageSize)
        clipRect = centered(cropSize).intersection(bounds)
    }
}
