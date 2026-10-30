// Numeric stand-in for SwiftUI's immutable color value on Linux only.
// The macOS runner compiles the actual SwiftUI/AppKit declarations instead.
#if os(Linux)
import Foundation

enum ColorScheme {
    case light
    case dark
}

struct Color: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    init(red: Double, green: Double, blue: Double, opacity: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        alpha = opacity
    }

    static let white = Color(red: 1, green: 1, blue: 1)
    static let black = Color(red: 0, green: 0, blue: 0)
    static let clear = Color(red: 0, green: 0, blue: 0, opacity: 0)
    // The measured palette never uses the system-accent convenience accessor.
    // Fail explicitly if that scope changes instead of inventing a macOS color.
    static var accentColor: Color {
        preconditionFailure("System accent color is outside the numeric Linux benchmark")
    }

    func opacity(_ opacity: Double) -> Color {
        Color(red: red, green: green, blue: blue, opacity: alpha * opacity)
    }
}
#endif
