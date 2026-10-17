// Linux compilation support only. The harness never creates a native surface.
// PlaybackRuntime and PlaybackSurfaceHost are the complete production protocols.
@_exported import Foundation

@MainActor public final class NSView { public init() {} }
@MainActor public final class NSMenu { public init() {} }
@MainActor public final class NSScreen { public init() {} }
