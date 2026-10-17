import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif

private typealias Geometry = ElasticPlaybackControlBarGeometry

private struct Scenario {
    let name: String
    let center: CGPoint
    let orientation: ElasticPlaybackControlBarOrientation
    let direction: ElasticPlaybackControlBarBendDirection
    let operation: String
    let size = CGSize(width: 1_280, height: 720)

    func geometry(center override: CGPoint? = nil) -> Geometry {
        Geometry(containerSize: size, center: override ?? center, utilityCount: 7,
                 bendDirection: direction, orientation: orientation)
    }
}

@main
enum ElasticGeometryBenchmark {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 2, let iterations = Int(arguments[1]), iterations > 0 else {
            fatalError("usage: geometry-benchmark SCENARIO ITERATIONS")
        }
        let name = arguments[0]
        let operation = String(name.split(separator: "_").last!)
        let center: CGPoint
        let orientation: ElasticPlaybackControlBarOrientation
        switch name.split(separator: "_").first! {
        case "straight": center = CGPoint(x: 640, y: 676); orientation = .right
        case "rotated": center = CGPoint(x: 1_234, y: 361); orientation = .down
        case "curved": center = CGPoint(x: 1_100, y: 676); orientation = .right
        case "slight": center = CGPoint(x: 800, y: 676); orientation = .right
        case "turned": center = CGPoint(x: 1_500, y: 676); orientation = .right
        default: fatalError("unknown scenario")
        }
        let scenario = Scenario(name: name, center: center, orientation: orientation,
                                direction: .up, operation: operation)
        let geometry = scenario.geometry()
        var locations: [CGPoint] = []
        for index in 0..<64 {
            let fraction = CGFloat(index) / 63
            let point = geometry.pointOnTrack(fraction: fraction)
            // Move across and just outside the track, as a real hover does.
            locations.append(CGPoint(x: point.x + CGFloat(index % 7 - 3),
                                     y: point.y + CGFloat(index % 61 - 30)))
        }
        // Run outside the measurement interval to load code and lazy runtime data.
        var checksum: CGFloat = 0
        for index in 0..<32 {
            checksum += perform(scenario, geometry, locations, index)
        }
        let cpuStart = cpuNanoseconds()
        let start = DispatchTime.now().uptimeNanoseconds
        for index in 0..<iterations {
            checksum += perform(scenario, geometry, locations, index)
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        let cpu = cpuNanoseconds() - cpuStart
        precondition(checksum.isFinite)
        #if canImport(SwiftUI)
        let pathBackend = "SwiftUI.Path"
        #else
        let pathBackend = "Foundation point collector (no native drawing)"
        #endif
        let result: [String: Any] = [
            "scenario": name, "iterations": iterations, "elapsed_ns": elapsed,
            "cpu_ns": cpu, "checksum": Double(checksum),
            "bend_progress": Double(geometry.bendProgress), "path_backend": pathBackend,
        ]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result,
                                                        options: [.sortedKeys]), as: UTF8.self))
    }

    // Keep the repeated operation observable and changing without timing JSON or
    // compiler-constant fixtures. Each variant uses the same call boundary.
    @inline(never)
    private static func perform(_ scenario: Scenario, _ geometry: Geometry,
                                _ locations: [CGPoint], _ index: Int) -> CGFloat {
        let fraction = CGFloat(index % 1_009) / 1_008
        switch scenario.operation {
        case "construction":
            let changedCenter = CGPoint(x: scenario.center.x,
                                        y: scenario.center.y - CGFloat(index % 13) / 8)
            let value = scenario.geometry(center: changedCenter)
            let bounds = value.surfaceBounds
            return bounds.minX + bounds.maxY + value.utilityPositions[3].x
        case "hover":
            let location = locations[index % locations.count]
            return (geometry.timelineFraction(at: location, maximumDistance: 16) ?? -1)
                + (geometry.containsSurface(location) ? 1 : 0)
        case "paths":
            let track = geometry.path(from: geometry.trackStartS, through: geometry.trackEndS)
            let progressEnd = geometry.trackStartS
                + (geometry.trackEndS - geometry.trackStartS) * fraction
            let progress = geometry.path(from: geometry.trackStartS, through: progressEnd)
            let bufferEnd = geometry.trackStartS
                + (geometry.trackEndS - geometry.trackStartS) * min(1, fraction + 0.15)
            let buffer = geometry.path(from: geometry.trackStartS, through: bufferEnd)
            return track.boundingRect.width + progress.boundingRect.minX
                + buffer.boundingRect.maxY + geometry.pointOnTrack(fraction: fraction).x
        case "tracking":
            let desired = geometry.grabPoint(surfaceFraction: fraction,
                                            localOffset: CGPoint(x: 4, y: -8))
            let result = Geometry.centerTracking(
                desiredPoint: CGPoint(x: desired.x + 2, y: desired.y - 1),
                surfaceFraction: fraction, localOffset: CGPoint(x: 4, y: -8),
                initialCenter: scenario.center, containerSize: scenario.size, utilityCount: 7,
                bendDirection: scenario.direction, orientation: scenario.orientation,
                maximumCorrection: Geometry.standardTrackingCorrection)
            return result.x + result.y
        default: fatalError("unknown operation")
        }
    }

    private static func cpuNanoseconds() -> UInt64 {
        var value = timespec()
        precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0)
        return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
    }
}
