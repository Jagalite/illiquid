import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private struct Case: Decodable {
    let id: String
    let category: String
    let format: String
    let source: String
}

private enum Outcome: Equatable {
    case success([UInt8])
    case failure(String)

    var label: String {
        switch self {
        case .success: "success"
        case let .failure(error): error
        }
    }

    var bytes: [UInt8] {
        switch self {
        case let .success(bytes): bytes
        case let .failure(error): Array(error.utf8)
        }
    }
}

private func original(_ input: Case) -> Outcome {
    let format: BaselineExternalTextSubtitleConverter.Format = input.format == "srt" ? .srt : .webVTT
    do {
        return .success(Array(try BaselineExternalTextSubtitleConverter.convert(input.source, format: format).utf8))
    } catch let error as BaselineExternalTextSubtitleConverter.ConversionError {
        switch error {
        case .missingWebVTTSignature: return .failure("missingWebVTTSignature")
        case .noValidCues(.srt): return .failure("noValidCues.srt")
        case .noValidCues(.webVTT): return .failure("noValidCues.webVTT")
        }
    } catch {
        return .failure("unexpected:" + String(reflecting: error))
    }
}

private func proposed(_ input: Case) -> Outcome {
    let format: ExternalTextSubtitleConverter.Format = input.format == "srt" ? .srt : .webVTT
    do {
        return .success(Array(try ExternalTextSubtitleConverter.convert(input.source, format: format).utf8))
    } catch let error as ExternalTextSubtitleConverter.ConversionError {
        switch error {
        case .missingWebVTTSignature: return .failure("missingWebVTTSignature")
        case .noValidCues(.srt): return .failure("noValidCues.srt")
        case .noValidCues(.webVTT): return .failure("noValidCues.webVTT")
        }
    } catch {
        return .failure("unexpected:" + String(reflecting: error))
    }
}

@main
private struct Differential {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            fatalError("Usage: differential CASES_JSON REPORT_JSON")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let inputs = try JSONDecoder().decode([Case].self, from: data)
        var categories: [String: Int] = [:]
        var results: [String: Int] = [:]
        var failureCount = 0
        var examples: [[String: Any]] = []
        var checksum: UInt64 = 0xcbf29ce484222325
        for input in inputs {
            let before = original(input)
            let after = proposed(input)
            categories[input.category, default: 0] += 1
            results[before.label, default: 0] += 1
            for byte in before.bytes {
                checksum = (checksum ^ UInt64(byte)) &* 0x100000001b3
            }
            if before != after {
                failureCount += 1
                if examples.count < 20 {
                    let left = before.bytes
                    let right = after.bytes
                    let offset = zip(left, right).enumerated().first(where: {
                        $0.element.0 != $0.element.1
                    })?.offset ?? min(left.count, right.count)
                    examples.append([
                        "id": input.id, "category": input.category, "format": input.format,
                        "source": input.source, "first_difference": offset,
                        "baseline_result": before.label, "candidate_result": after.label,
                        "baseline_bytes": left.count, "candidate_bytes": right.count,
                        "baseline_text": String(decoding: left, as: UTF8.self),
                        "candidate_text": String(decoding: right, as: UTF8.self),
                    ])
                }
            }
        }
        let report: [String: Any] = [
            "cases": inputs.count, "categories": categories, "baseline_outcomes": results,
            "differences": failureCount, "failure_examples": examples,
            "baseline_output_checksum_fnv1a64": String(checksum, radix: 16),
            "comparison": "Exact UTF-8 bytes of complete ASS output or matched typed conversion errors",
        ]
        let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try json.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        print("Checked \(inputs.count) cases; \(failureCount) differences; baseline checksum \(String(checksum, radix: 16))")
        if failureCount > 0 { exit(1) }
    }
}
