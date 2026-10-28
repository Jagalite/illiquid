import Foundation
@testable import IlliquidNativePlayback

/// Runtime JSON inputs keep the tested strings out of either optimized module.
/// Each binary uses one complete, separately compiled production source variant.
private struct TimestampCase: Decodable {
    let id: String
    let format: String
    let source: String
    let expected_error: String?
    let expected_dialogue: String?
}

private struct TimestampRecord: Encodable {
    let id: String
    let output: String?
    let error: String?
}

private struct ParityFailure: Error, CustomStringConvertible {
    let description: String
}

@main
struct TimestampParity {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw ParityFailure(description: "Usage: TimestampParity CASES.json")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let cases = try JSONDecoder().decode([TimestampCase].self, from: data)
        guard !cases.isEmpty, cases.count < 30_000,
              Set(cases.map(\.id)).count == cases.count else {
            throw ParityFailure(description: "Corpus is empty, oversized, or has duplicate IDs")
        }
        var records: [TimestampRecord] = []
        records.reserveCapacity(cases.count)
        for item in cases {
            guard item.expected_error == nil || item.expected_dialogue == nil else {
                throw ParityFailure(description: "\(item.id): contradictory expected results")
            }
            let format: ExternalTextSubtitleConverter.Format
            switch item.format {
            case "srt": format = .srt
            case "vtt": format = .webVTT
            default:
                throw ParityFailure(description: "\(item.id): unknown input format \(item.format)")
            }
            do {
                let result = try ExternalTextSubtitleConverter.convert(item.source, format: format)
                guard item.expected_error == nil else {
                    throw ParityFailure(description: "\(item.id): succeeded but expected \(item.expected_error!)")
                }
                if let dialogue = item.expected_dialogue {
                    let expected = ExternalTextSubtitleConverter.defaultASSHeader + dialogue
                    guard result.utf8.elementsEqual(expected.utf8) else {
                        throw ParityFailure(description: "\(item.id): full UTF-8 output differs from arithmetic/contract expectation")
                    }
                }
                records.append(TimestampRecord(
                    id: item.id, output: Data(result.utf8).base64EncodedString(), error: nil
                ))
            } catch let conversionError as ExternalTextSubtitleConverter.ConversionError {
                let code: String
                switch conversionError {
                case .missingWebVTTSignature:
                    code = "missingWebVTTSignature"
                case .noValidCues(.srt):
                    code = "noValidCues.srt"
                case .noValidCues(.webVTT):
                    code = "noValidCues.webVTT"
                }
                guard item.expected_dialogue == nil else {
                    throw ParityFailure(description: "\(item.id): threw \(code) but expected successful conversion")
                }
                if let expected = item.expected_error, expected != code {
                    throw ParityFailure(description: "\(item.id): threw \(code), expected \(expected)")
                }
                records.append(TimestampRecord(id: item.id, output: nil, error: code))
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(records))
    }
}
