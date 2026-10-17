import Foundation

#if canImport(SwiftUI)
import SwiftUI
#else
// Portable tests need only the centerline's move/line operations. Timing this
// stand-in does not measure SwiftUI Path construction, drawing, or layout.
struct Path {
    private var points: [CGPoint] = []
    mutating func move(to point: CGPoint) { points.append(point) }
    mutating func addLine(to point: CGPoint) { points.append(point) }
    var boundingRect: CGRect {
        guard let first = points.first else { return .zero }
        var bounds = CGRect(origin: first, size: .zero)
        for point in points.dropFirst() {
            bounds = bounds.union(CGRect(origin: point, size: .zero))
        }
        return bounds
    }
}
#endif
