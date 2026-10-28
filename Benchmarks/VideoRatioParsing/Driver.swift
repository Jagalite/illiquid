import Foundation
import CoreGraphics
import Dispatch
import Darwin
import IlliquidCore

// This client is compiled separately from the optimized production module.
// Its changing inputs and consumed results cross a non-inlinable module boundary.
struct GeometryInput {
    let source: CGSize
    let bounds: CGRect
    let settings: VideoAdjustmentState
}

let scalarInputs = ["1", "1.25", "1.3333333333333333", "1.5", "1.6", "1.7777777777777777",
    "1.85", "2", "2.35", "2.39", "2.4", "0.75", "0.5625", "0.8", "0.1", "10"]
let colonInputs = ["16:9", "4:3", "21:9", "1:1", "3:2", "16:10", "5:4", "9:16",
    "2.35:1", "2.39:1", "2.4:1", "185:100", "64:45", "40:33", "1:10", "10:1"]
let invalidInputs = ["", "auto", ":", "16:", ":9", "16:9:1", "0", "0:1", "1:0", "-1",
    "nan", "inf", "11", "0.01", "16/9", "１６:９"]

func settings(_ aspect: String?, _ crop: String?, _ mode: VideoScaleMode?) -> VideoAdjustmentState {
    var result = VideoAdjustmentState(aspectRatio: aspect, crop: crop)
    result.scaleMode = mode
    return result
}

func geometryInputs(_ scenario: String) -> [GeometryInput] {
    let sizes = [CGSize(width: 1920, height: 1080), CGSize(width: 3840, height: 2160),
        CGSize(width: 1440, height: 1080), CGSize(width: 720, height: 480),
        CGSize(width: 1080, height: 1920), CGSize(width: 2560, height: 1080),
        CGSize(width: 1280, height: 720), CGSize(width: 4096, height: 2160)]
    return (0..<32).map { index in
        let ratio = index.isMultiple(of: 2) ? scalarInputs[index / 2] : colonInputs[index / 2]
        let crop = colonInputs[(index * 7 + 3) & 15]
        let aspectValue: String? = switch scenario {
        case "geometry_aspect", "geometry_both": ratio
        case "geometry_invalid": invalidInputs[index & 15]
        default: nil
        }
        let cropValue: String? = switch scenario {
        case "geometry_crop", "geometry_both": crop
        case "geometry_invalid": invalidInputs[(index + 5) & 15]
        default: nil
        }
        let mode: VideoScaleMode? = index % 3 == 0 ? nil : (index % 3 == 1 ? .fit : .fill)
        return GeometryInput(source: sizes[index & 7],
            bounds: CGRect(x: CGFloat(index % 5), y: CGFloat(index % 7),
                           width: CGFloat(640 + (index % 8) * 160), height: CGFloat(360 + (index % 6) * 90)),
            settings: settings(aspectValue, cropValue, mode))
    }
}

func coordinates(_ geometry: VideoPresentationGeometry) -> [Double] {
    [Double(geometry.imageRect.origin.x), Double(geometry.imageRect.origin.y),
     Double(geometry.imageRect.size.width), Double(geometry.imageRect.size.height),
     Double(geometry.clipRect.origin.x), Double(geometry.clipRect.origin.y),
     Double(geometry.clipRect.size.width), Double(geometry.clipRect.size.height)]
}

func bits(_ value: Double?) -> String { value.map { String($0.bitPattern, radix: 16) } ?? "nil" }

func ratioCorpus() -> [String?] {
    var values: [String?] = [nil]
    let spellings = scalarInputs + colonInputs + invalidInputs + [
        "+1", "-0", "+0", "-0.0", "1.", ".5", "+.5", "01", "1e0", "1E+0", "1e-1",
        "0x1p0", "0X1.AP+1", "0x1.8p1", "0x1p-4", "0x1p1024", "0x1p-1074",
        "NaN", "NAN", "+nan", "-nan", "nan(1)", "Infinity", "+inf", "-Infinity",
        "1e309", "1e-400", "5e-324", "1.7976931348623157e308", "1_0", "1,5",
        " 1", "1 ", "\t1", "1\n", "\r1", "\u{00a0}1", "1\u{200b}", "١", "１",
        "16：9", "16∶9", "16:\u{301}9", "16\u{301}:9", "16:\u{fe0f}9", "16:\u{200d}9",
        "\u{0}1", "1\u{0}:1", "1\r\n:1", "++1", "--1", "1:1:", "1::1",
        "1:1e309", "1e309:1e309", "5e-324:5e-324", "1e308:1e308",
        String(repeating: "1", count: 4096), "1" + String(repeating: ":", count: 4096)]
    for text in spellings {
        values.append(text)
        // Every Character-boundary truncation, including the empty string.
        // The long rejection probes are already covered without quadratic copies.
        if text.utf8.count < 256 {
            values.append("")
            for end in text.indices { values.append(String(text[..<end])) }
        }
    }
    let fields = ["", "0", "-0", "1", "+1", "10", "16", "9", "0.1", "0.01", "1e1",
        "0x1p0", "1e308", "5e-324", "nan", "inf", "-1", " 1", "１", "1\u{0}"]
    for a in fields { for b in fields { values.append(a + ":" + b) } }
    for edge in [Double(0.1), Double(10)] {
        for number in [edge.nextDown, edge, edge.nextUp] {
            values.append(String(number)); values.append(String(number) + ":1")
            values.append("1:" + String(1 / number))
        }
    }
    var seen = Set<String>()
    return values.filter { value in value.map { seen.insert($0).inserted } ?? true }
}

func verify() -> [String: Any] {
    let expected: [(String?, Double?)] = [(nil, nil), ("", nil), ("1", 1), ("16:9", 16.0 / 9),
        ("4:3", 4.0 / 3), ("1:10", 0.1), ("10:1", 10), ("0.1", 0.1), ("10", 10),
        ("0.09999999999999999", nil), ("10.000000000000002", nil), ("1:0", nil),
        ("-1", nil), ("nan", nil), ("inf", nil), ("1:1:1", nil), (":1", nil), ("1:", nil)]
    for (input, output) in expected { precondition(bits(VideoPresentationGeometry.ratio(input)) == bits(output)) }
    let source = CGSize(width: 200, height: 100), bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
    let authored: [(VideoAdjustmentState, CGRect, CGRect)] = [
        (settings(nil, nil, .fit), CGRect(x: 0, y: 25, width: 100, height: 50), CGRect(x: 0, y: 25, width: 100, height: 50)),
        (settings(nil, nil, .fill), CGRect(x: -50, y: 0, width: 200, height: 100), bounds),
        (settings(nil, "1:1", .fit), CGRect(x: -50, y: 0, width: 200, height: 100), bounds),
        (settings("1:1", nil, .fit), bounds, bounds)]
    for (adjustments, image, clip) in authored {
        let result = VideoPresentationGeometry(sourceSize: source, bounds: bounds, adjustments: adjustments)
        precondition(result.imageRect == image && result.clipRect == clip)
    }
    let corpus = ratioCorpus()
    let ratioRows: [[String: Any]] = corpus.map {
        ["input": $0.map { $0 as Any } ?? NSNull(), "bits": bits(VideoPresentationGeometry.ratio($0))]
    }
    var geometryRows: [[String: Any]] = []
    func append(_ input: GeometryInput) {
        let result = VideoPresentationGeometry(sourceSize: input.source, bounds: input.bounds, adjustments: input.settings)
        geometryRows.append([
            "source": [Double(input.source.width), Double(input.source.height)].map { bits($0) },
            "bounds": [Double(input.bounds.origin.x), Double(input.bounds.origin.y), Double(input.bounds.size.width), Double(input.bounds.size.height)].map { bits($0) },
            "aspect": input.settings.aspectRatio.map { $0 as Any } ?? NSNull(),
            "crop": input.settings.crop.map { $0 as Any } ?? NSNull(), "scale": input.settings.scaleMode?.rawValue ?? "nil",
            "rect_bits": coordinates(result).map { bits($0) }])
    }
    let modes: [VideoScaleMode?] = [nil, .fit, .fill]
    for (index, text) in corpus.enumerated() {
        for mode in modes {
            for pair in [(text, nil as String?), (nil as String?, text), (text, colonInputs[index & 15])] {
                append(GeometryInput(source: source, bounds: bounds, settings: settings(pair.0, pair.1, mode)))
            }
        }
    }
    let dimensions: [CGFloat] = [0, -1, 1, 1080, .leastNonzeroMagnitude, .greatestFiniteMagnitude, .infinity, .nan]
    for dimension in dimensions {
        for mode in modes {
            for adjustment in [settings(nil, nil, mode), settings("16:9", "1:1", mode), settings("bad", "1:0", mode)] {
                for size in [CGSize(width: dimension, height: 100), CGSize(width: 200, height: dimension)] {
                    append(GeometryInput(source: size, bounds: bounds, settings: adjustment))
                }
                for rectangle in [CGRect(x: 0, y: 0, width: dimension, height: 100),
                                  CGRect(x: 0, y: 0, width: 100, height: dimension),
                                  CGRect(x: dimension, y: -3, width: 100, height: 100)] {
                    append(GeometryInput(source: source, bounds: rectangle, settings: adjustment))
                }
            }
        }
    }
    return ["authored_checks": expected.count + authored.count, "ratio": ratioRows, "geometry": geometryRows]
}

@inline(never)
func ratioLoop(_ inputs: [String?], _ iterations: Int) -> UInt64 {
    var checksum: UInt64 = 0xcbf29ce484222325
    for index in 0..<iterations {
        let result = VideoPresentationGeometry.ratio(inputs[index & 31])
        checksum = (checksum &* 1099511628211) ^ (result?.bitPattern ?? 0x7ff8000000000001)
    }
    return checksum
}

@inline(never)
func geometryLoop(_ inputs: [GeometryInput], _ iterations: Int) -> UInt64 {
    var checksum: UInt64 = 0xcbf29ce484222325
    for index in 0..<iterations {
        let input = inputs[index & 31]
        let result = VideoPresentationGeometry(sourceSize: input.source, bounds: input.bounds, adjustments: input.settings)
        // Consume all eight coordinates without allocating an output array.
        checksum = (checksum &* 1099511628211) ^ Double(result.imageRect.origin.x).bitPattern
        checksum = (checksum &* 1099511628211) ^ Double(result.imageRect.origin.y).bitPattern
        checksum = (checksum &* 1099511628211) ^ Double(result.imageRect.size.width).bitPattern
        checksum = (checksum &* 1099511628211) ^ Double(result.imageRect.size.height).bitPattern
        checksum = (checksum &* 1099511628211) ^ Double(result.clipRect.origin.x).bitPattern
        checksum = (checksum &* 1099511628211) ^ Double(result.clipRect.origin.y).bitPattern
        checksum = (checksum &* 1099511628211) ^ Double(result.clipRect.size.width).bitPattern
        checksum = (checksum &* 1099511628211) ^ Double(result.clipRect.size.height).bitPattern
    }
    return checksum
}

func cpuNanoseconds() -> UInt64 {
    var value = timespec()
    precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0)
    return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
}

@main
struct Main {
    static func main() throws {
        let arguments = CommandLine.arguments
        let output: [String: Any]
        if arguments.count == 2 && arguments[1] == "verify" {
            output = verify()
        } else {
            precondition(arguments.count == 3)
            let scenario = arguments[1], iterations = Int(arguments[2])!
            precondition(iterations > 0)
            let seeds: [String?] = switch scenario {
            case "ratio_nil": Array(repeating: nil, count: 16)
            case "ratio_scalar": scalarInputs.map { $0 }
            case "ratio_colon": colonInputs.map { $0 }
            case "ratio_invalid": invalidInputs.map { $0 }
            default: []
            }
            let ratios = seeds + Array(seeds.reversed())
            let geometries = scenario.hasPrefix("geometry_") ? geometryInputs(scenario) : []
            precondition(ratios.count == 32 || geometries.count == 32)
            let run: (Int) -> UInt64 = ratios.isEmpty
                ? { geometryLoop(geometries, $0) } : { ratioLoop(ratios, $0) }
            let warm = run(min(iterations, 8192))
            let cpuStart = cpuNanoseconds(), wallStart = DispatchTime.now().uptimeNanoseconds
            let checksum = run(iterations)
            let wall = DispatchTime.now().uptimeNanoseconds - wallStart, cpu = cpuNanoseconds() - cpuStart
            output = ["scenario": scenario, "iterations": iterations, "wall_ns": wall, "cpu_ns": cpu,
                      "checksum": String(checksum), "warm_checksum": String(warm)]
        }
        let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
