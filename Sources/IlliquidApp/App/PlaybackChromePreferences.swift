import CoreFoundation
import Foundation

enum PlaybackChromePreferences {
    static let storageKey = "Illiquid.controls-auto-hide-timeout"
    static let defaultInterval: TimeInterval = 2.5
    static let allowedRange: ClosedRange<TimeInterval> = 0.5...60.0

    static func resolve(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite, allowedRange.contains(value) else {
            return defaultInterval
        }
        return value
    }

    static func load(defaults: UserDefaults = .standard) -> TimeInterval {
        guard let storedValue = defaults.object(forKey: storageKey) as? NSNumber,
            CFGetTypeID(storedValue) != CFBooleanGetTypeID()
        else {
            return defaultInterval
        }
        return resolve(storedValue.doubleValue)
    }
}
