import Foundation

public struct PictureInPictureState: Equatable, Sendable {
    public let isPossible: Bool
    public let isActive: Bool

    public init(isPossible: Bool, isActive: Bool) {
        self.isPossible = isPossible
        self.isActive = isActive
    }

    public static let unavailable = Self(isPossible: false, isActive: false)

    public var canToggle: Bool { isPossible || isActive }
}
