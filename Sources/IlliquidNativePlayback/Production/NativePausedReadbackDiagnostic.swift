import Foundation

/// On-demand, scalar-only readback evidence. Does not retain a decoded frame.
public struct NativePausedReadbackDiagnostic: Codable, Sendable {
    public let hasPixelBuffer: Bool
    public let currentGeneration: Int?
    public let displayedGeneration: Int?
    public let displayedPTS: Double?
    public let rendererRate: Float
    public let seekInProgress: Bool
    public let isCurrent: Bool
}
