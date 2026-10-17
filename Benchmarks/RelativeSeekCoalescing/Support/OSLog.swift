// Linux compilation support only; this does not qualify native logging costs.
// macOS uses its actual OSLog module. This support never changes driver logic.
public struct Logger {
    public init(subsystem: String, category: String) {}
    public func info(_ message: @autoclosure () -> String) {}
}
