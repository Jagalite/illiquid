import Foundation

// Both executables compile this driver with the complete, unmodified converter
// from either the pinned baseline commit or the current checkout.
func convert(_ source: String, format: ExternalTextSubtitleConverter.Format) throws -> String {
    try ExternalTextSubtitleConverter.convert(source, format: format)
}

let arguments = CommandLine.arguments
guard arguments.count >= 5 else {
    fatalError("usage: converter emit|measure srt|webvtt INPUT OUTPUT_OR_EXPECTED [ROUNDS]")
}
let mode = arguments[1]
let format: ExternalTextSubtitleConverter.Format
switch arguments[2] {
case "srt": format = .srt
case "webvtt": format = .webVTT
default: fatalError("unknown format")
}
let source = try String(contentsOfFile: arguments[3], encoding: .utf8)
let outputURL = URL(fileURLWithPath: arguments[4])

switch mode {
case "emit":
    try Data(convert(source, format: format).utf8).write(to: outputURL)
case "measure":
    guard arguments.count == 6, let rounds = Int(arguments[5]), rounds > 0 else {
        fatalError("measure requires positive ROUNDS")
    }
    let expected = try Data(contentsOf: outputURL)
    // Warmup, disk reads, output comparison, and JSON encoding are not timed.
    guard try convert(source, format: format).utf8.elementsEqual(expected) else {
        fatalError("warmup output differs from baseline bytes")
    }
    var milliseconds: [Double] = []
    milliseconds.reserveCapacity(rounds)
    let clock = ContinuousClock()
    for _ in 0..<rounds {
        let start = clock.now
        let converted = try convert(source, format: format)
        let elapsed = start.duration(to: clock.now).components
        let time = Double(elapsed.seconds) * 1_000
            + Double(elapsed.attoseconds) / 1_000_000_000_000_000
        guard converted.utf8.elementsEqual(expected) else {
            fatalError("measured output differs from baseline bytes")
        }
        milliseconds.append(time)
    }
    let record: [String: Any] = [
        "milliseconds": milliseconds,
        "input_bytes": source.utf8.count,
        "output_bytes": expected.count,
        "verified_rounds": rounds,
    ]
    let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
default:
    fatalError("unknown mode")
}
