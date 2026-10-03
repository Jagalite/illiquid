import Foundation

public enum PlaybackTimeInput {
    /// Seconds, minutes:seconds or hours:minutes:seconds. Fractional seconds
    /// are allowed; signs, exponents and out-of-range fields are rejected.
    public static func seconds(_ text: String, duration: TimeInterval) -> TimeInterval? {
        guard duration.isFinite, duration > 0 else { return nil }
        let fields = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(fields.count) else { return nil }
        var result = 0.0
        for (index, field) in fields.enumerated() {
            let last = index == fields.count - 1
            guard !field.isEmpty,
                  field.allSatisfy({ $0.isASCII && ($0.isNumber || (last && $0 == ".")) }),
                  let value = Double(field), value.isFinite, value >= 0,
                  index == 0 || value < 60 else { return nil }
            result = result * 60 + value
        }
        return result.isFinite && result <= duration ? result : nil
    }
}
