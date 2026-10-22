import CFFmpeg
import CoreVideo
import Darwin
import Foundation

// Real AVFrame side data and CoreVideo attachments exercise the exact production
// methods extracted by run.py. Fixture construction is outside timed regions.
private enum MetadataKind: String, CaseIterable {
    case none, hdr, masteringOnly, lightOnly, noPrimaries, noLuminance, noFlags
    case shortMastering, shortLight, oversized, clipped, lightLimits, alternate, hlg, unknown
}

private let goldenMastering = "33c286c41d4c0bb884d03e803d1340420098968000000032"
private let goldenLight = "03e80190"
private let seededMastering = Data(repeating: 0xa5, count: 24)
private let seededLight = Data(repeating: 0x5a, count: 4)

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}

private func hex(_ data: Data?) -> String? {
    data.map { $0.map { String(format: "%02x", $0) }.joined() }
}

private func configure(_ frame: UnsafeMutablePointer<AVFrame>, kind: MetadataKind) {
    av_frame_remove_side_data(frame, AV_FRAME_DATA_MASTERING_DISPLAY_METADATA)
    av_frame_remove_side_data(frame, AV_FRAME_DATA_CONTENT_LIGHT_LEVEL)
    frame.pointee.color_primaries = AVCOL_PRI_BT2020
    frame.pointee.color_trc = AVCOL_TRC_SMPTE2084
    frame.pointee.colorspace = AVCOL_SPC_BT2020_NCL
    if kind == .none {
        frame.pointee.color_primaries = AVCOL_PRI_BT709
        frame.pointee.color_trc = AVCOL_TRC_BT709
        frame.pointee.colorspace = AVCOL_SPC_BT709
    } else if kind == .hlg {
        frame.pointee.color_trc = AVCOL_TRC_ARIB_STD_B67
    } else if kind == .unknown {
        frame.pointee.color_primaries = AVCOL_PRI_UNSPECIFIED
        frame.pointee.color_trc = AVCOL_TRC_UNSPECIFIED
        frame.pointee.colorspace = AVCOL_SPC_UNSPECIFIED
    }

    let hasMastering = ![MetadataKind.none, .lightOnly, .lightLimits, .hlg, .unknown].contains(kind)
    if hasMastering {
        let size = kind == .shortMastering ? MemoryLayout<AVMasteringDisplayMetadata>.size - 1
            : MemoryLayout<AVMasteringDisplayMetadata>.size + (kind == .oversized ? 16 : 0)
        guard let side = av_frame_new_side_data(frame, AV_FRAME_DATA_MASTERING_DISPLAY_METADATA, size),
              let bytes = side.pointee.data else { fatalError("mastering side-data allocation") }
        bytes.initialize(repeating: 0, count: size)
        if kind != .shortMastering {
            let metadata = UnsafeMutableRawPointer(bytes).assumingMemoryBound(to: AVMasteringDisplayMetadata.self)
            metadata.pointee.has_primaries = (kind == .noPrimaries || kind == .noFlags) ? 0 : 1
            metadata.pointee.has_luminance = (kind == .noLuminance || kind == .noFlags) ? 0 : 1
            metadata.pointee.display_primaries.0.0 = AVRational(num: 34000, den: 50000)
            metadata.pointee.display_primaries.0.1 = AVRational(num: 16000, den: 50000)
            metadata.pointee.display_primaries.1.0 = AVRational(num: 13250, den: 50000)
            metadata.pointee.display_primaries.1.1 = AVRational(num: 34500, den: 50000)
            metadata.pointee.display_primaries.2.0 = AVRational(num: 7500, den: 50000)
            metadata.pointee.display_primaries.2.1 = AVRational(num: 3000, den: 50000)
            metadata.pointee.white_point.0 = AVRational(num: 15635, den: 50000)
            metadata.pointee.white_point.1 = AVRational(num: 16450, den: 50000)
            metadata.pointee.max_luminance = AVRational(num: kind == .alternate ? 2000 : 1000, den: 1)
            metadata.pointee.min_luminance = AVRational(num: 50, den: 10000)
            if kind == .clipped {
                metadata.pointee.display_primaries.0.0 = AVRational(num: -1, den: 1)
                metadata.pointee.display_primaries.0.1 = AVRational(num: 2, den: 1)
            }
        }
    }

    let hasLight = ![MetadataKind.none, .masteringOnly, .hlg, .unknown].contains(kind)
    if hasLight {
        let size = kind == .shortLight ? MemoryLayout<AVContentLightMetadata>.size - 1
            : MemoryLayout<AVContentLightMetadata>.size + (kind == .oversized ? 16 : 0)
        guard let side = av_frame_new_side_data(frame, AV_FRAME_DATA_CONTENT_LIGHT_LEVEL, size),
              let bytes = side.pointee.data else { fatalError("light side-data allocation") }
        bytes.initialize(repeating: 0, count: size)
        if kind != .shortLight {
            let metadata = UnsafeMutableRawPointer(bytes).assumingMemoryBound(to: AVContentLightMetadata.self)
            metadata.pointee.MaxCLL = kind == .lightLimits ? 65536 : (kind == .alternate ? 2000 : 1000)
            metadata.pointee.MaxFALL = kind == .lightLimits ? 65535 : (kind == .alternate ? 800 : 400)
        }
    }
}

private func makeBuffer(_ format: OSType) -> CVPixelBuffer {
    var result: CVPixelBuffer?
    let status = CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, format, nil, &result)
    require(status == kCVReturnSuccess && result != nil, "pixel-buffer allocation")
    return result!
}

private func seed(_ buffer: CVPixelBuffer) {
    CVBufferSetAttachment(buffer, kCVImageBufferMasteringDisplayColorVolumeKey,
                          seededMastering as CFData, .shouldNotPropagate)
    CVBufferSetAttachment(buffer, kCVImageBufferContentLightLevelInfoKey,
                          seededLight as CFData, .shouldNotPropagate)
    CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey,
                          kCVImageBufferColorPrimaries_SMPTE_C, .shouldNotPropagate)
    CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey,
                          kCVImageBufferTransferFunction_ITU_R_709_2, .shouldNotPropagate)
    CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
                          kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldNotPropagate)
}

private struct Snapshot: Codable, Equatable {
    let name: String
    let returnedMastering: String?
    let returnedLight: String?
    let attachments: [String: String]
    let modes: [String: UInt32]
}

private func snapshot(_ name: String, buffer: CVPixelBuffer,
                      payloads: (masteringMetadata: Data?, contentLightMetadata: Data?)) -> Snapshot {
    var values: [String: String] = [:]
    var modes: [String: UInt32] = [:]
    let keys: [(String, CFString)] = [
        ("mastering", kCVImageBufferMasteringDisplayColorVolumeKey),
        ("light", kCVImageBufferContentLightLevelInfoKey),
        ("primaries", kCVImageBufferColorPrimariesKey),
        ("transfer", kCVImageBufferTransferFunctionKey),
        ("matrix", kCVImageBufferYCbCrMatrixKey),
    ]
    for (label, key) in keys {
        var mode: CVAttachmentMode = .shouldNotPropagate
        if let value = CVBufferCopyAttachment(buffer, key, &mode) {
            if let data = value as? Data {
                values[label] = hex(data)
            } else if let string = value as? String {
                values[label] = string
            } else {
                fatalError("unexpected attachment type for \(label)")
            }
            modes[label] = mode.rawValue
        }
    }
    return Snapshot(name: name, returnedMastering: hex(payloads.masteringMetadata),
                    returnedLight: hex(payloads.contentLightMetadata), attachments: values, modes: modes)
}

private func expectedMastering(_ kind: MetadataKind) -> String? {
    switch kind {
    case .none, .lightOnly, .lightLimits, .noPrimaries, .noLuminance, .noFlags, .shortMastering, .hlg, .unknown:
        return nil
    case .alternate:
        return "33c286c41d4c0bb884d03e803d13404201312d0000000032"
    case .clipped:
        return "33c286c41d4c0bb80000ffff3d1340420098968000000032"
    default:
        return goldenMastering
    }
}

private func expectedLight(_ kind: MetadataKind) -> String? {
    switch kind {
    case .none, .masteringOnly, .shortLight, .hlg, .unknown: return nil
    case .lightLimits: return "0000ffff"
    case .alternate: return "07d00320"
    default: return goldenLight
    }
}

private func check(_ result: Snapshot, kind: MetadataKind, format: OSType, seeded: Bool) {
    let mastering = expectedMastering(kind)
    let light = expectedLight(kind)
    require(result.returnedMastering == mastering, "\(result.name): mastering bytes")
    require(result.returnedLight == light, "\(result.name): light bytes")
    for (key, expected, inherited) in [("mastering", mastering, hex(seededMastering)),
                                       ("light", light, hex(seededLight))] {
        require(result.attachments[key] == (expected ?? (seeded ? inherited : nil)),
                "\(result.name): \(key) attachment")
        if expected != nil {
            require(result.modes[key] == CVAttachmentMode.shouldPropagate.rawValue,
                    "\(result.name): propagation mode")
        } else if seeded {
            require(result.modes[key] == CVAttachmentMode.shouldNotPropagate.rawValue,
                    "\(result.name): inherited mode")
        }
    }
    if format == kCVPixelFormatType_32BGRA {
        require(result.attachments["matrix"] == nil, "BGRA must remove YCbCr matrix")
    } else if kind == .unknown {
        require(result.attachments["matrix"] == (seeded ? kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String : nil),
                "unknown matrix must preserve inherited value")
    } else {
        let matrix = kind == .none ? kCVImageBufferYCbCrMatrix_ITU_R_709_2 : kCVImageBufferYCbCrMatrix_ITU_R_2020
        require(result.attachments["matrix"] == matrix as String, "matrix mapping")
    }
    if kind == .unknown {
        require(result.attachments["primaries"] == (seeded ? kCVImageBufferColorPrimaries_SMPTE_C as String : nil),
                "unknown primaries must preserve inherited value")
        require(result.attachments["transfer"] == (seeded ? kCVImageBufferTransferFunction_ITU_R_709_2 as String : nil),
                "unknown transfer must preserve inherited value")
    } else {
        let primaries = kind == .none ? kCVImageBufferColorPrimaries_ITU_R_709_2 : kCVImageBufferColorPrimaries_ITU_R_2020
        let transfer = kind == .none ? kCVImageBufferTransferFunction_ITU_R_709_2
            : (kind == .hlg ? kCVImageBufferTransferFunction_ITU_R_2100_HLG : kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ)
        require(result.attachments["primaries"] == primaries as String, "primaries mapping")
        require(result.attachments["transfer"] == transfer as String, "transfer mapping")
    }
}

private func verify() -> [Snapshot] {
    let processor = MetadataProcessor()
    guard let frame = av_frame_alloc() else { fatalError("frame allocation") }
    var owned: UnsafeMutablePointer<AVFrame>? = frame
    defer { av_frame_free(&owned) }
    var trace: [Snapshot] = []
    let formats: [OSType] = [kCVPixelFormatType_32BGRA,
                            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange]
    for format in formats {
        for kind in MetadataKind.allCases {
            for seeded in [false, true] {
                configure(frame, kind: kind)
                let buffer = makeBuffer(format)
                if seeded { seed(buffer) }
                let name = "\(format)/\(kind.rawValue)/seeded=\(seeded)"
                let result = snapshot(name, buffer: buffer,
                                      payloads: processor.metadata(frame: frame, pixelBuffer: buffer))
                check(result, kind: kind, format: format, seeded: seeded)
                trace.append(result)
            }
        }
    }

    // One mutable source frame changes and loses side data. Keep the first
    // returned payload and output buffer alive to detect borrowed/stale data.
    configure(frame, kind: .hdr)
    let retainedBuffer = makeBuffer(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
    let retained = processor.metadata(frame: frame, pixelBuffer: retainedBuffer)
    let first = snapshot("retained", buffer: retainedBuffer, payloads: retained)
    for kind in [MetadataKind.alternate, .none, .hdr, .shortMastering, .lightLimits, .unknown] {
        configure(frame, kind: kind)
        let buffer = makeBuffer(kCVPixelFormatType_32BGRA)
        let result = snapshot("mutated/\(kind.rawValue)", buffer: buffer,
                              payloads: processor.metadata(frame: frame, pixelBuffer: buffer))
        check(result, kind: kind, format: kCVPixelFormatType_32BGRA, seeded: false)
        require(snapshot("retained", buffer: retainedBuffer, payloads: retained) == first,
                "earlier payload or separate buffer changed")
        trace.append(result)
    }
    av_frame_unref(frame)
    require(snapshot("retained", buffer: retainedBuffer, payloads: retained) == first,
            "payloads must outlive source side data")
    trace.append(first)

    // Pixel-buffer reuse must retain absent metadata under the existing policy,
    // and replace it when new source metadata arrives.
    let reused = makeBuffer(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    var lastMastering: String?
    var lastLight: String?
    for (index, kind) in [MetadataKind.hdr, .alternate, .none, .noFlags, .lightLimits, .hdr].enumerated() {
        configure(frame, kind: kind)
        let result = snapshot("reuse/\(index)/\(kind.rawValue)", buffer: reused,
                              payloads: processor.metadata(frame: frame, pixelBuffer: reused))
        require(result.returnedMastering == expectedMastering(kind), "reused source mastering")
        require(result.returnedLight == expectedLight(kind), "reused source light")
        lastMastering = expectedMastering(kind) ?? lastMastering
        lastLight = expectedLight(kind) ?? lastLight
        require(result.attachments["mastering"] == lastMastering, "reused attachment mastering")
        require(result.attachments["light"] == lastLight, "reused attachment light")
        trace.append(result)
    }
    return trace
}

private final class Fixture {
    let frame: UnsafeMutablePointer<AVFrame>
    let buffer: CVPixelBuffer

    init(kind: MetadataKind, format: OSType, seeded: Bool = false) {
        guard let frame = av_frame_alloc() else { fatalError("frame allocation") }
        self.frame = frame
        self.buffer = makeBuffer(format)
        configure(frame, kind: kind)
        if seeded { seed(buffer) }
    }

    deinit {
        var owned: UnsafeMutablePointer<AVFrame>? = frame
        av_frame_free(&owned)
    }
}

private func fixtures(_ name: String) -> [Fixture] {
    let bgra = kCVPixelFormatType_32BGRA
    let nv12 = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    let p010 = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
    let specification: [(MetadataKind, OSType, Bool)]
    switch name {
    case "sdr_bgra": specification = [(.none, bgra, false)]
    case "sdr_nv12", "sdr_nv12_cleared": specification = [(.none, nv12, false)]
    case "hdr10_bgra": specification = [(.hdr, bgra, false)]
    case "hdr10_p010", "hdr10_p010_cleared": specification = [(.hdr, p010, false)]
    case "mastering_only": specification = [(.masteringOnly, p010, false)]
    case "light_only": specification = [(.lightOnly, p010, false)]
    case "metadata_changes": specification = [(.hdr, p010, false), (.alternate, bgra, false),
                                                (.none, nv12, false), (.shortMastering, p010, false)]
    case "preexisting_attachments": specification = [(.unknown, p010, true)]
    default: fatalError("unknown case: \(name)")
    }
    // A small ring resembles separate decoded frames without timing allocations
    // or permitting the compiler to replace a single fixture with a constant.
    return (0..<32).map { index in
        let item = specification[index % specification.count]
        return Fixture(kind: item.0, format: item.1, seeded: item.2)
    }
}

private func cpuNanoseconds() -> UInt64 {
    var value = timespec()
    require(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0, "CPU clock")
    return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
}

private struct Timing: Codable {
    let `case`: String
    let iterations: Int
    let wall_ns: UInt64
    let cpu_ns: UInt64
    let checksum: UInt64
}

private func benchmark(_ name: String, iterations: Int) -> Timing {
    let values = fixtures(name)
    let processor = MetadataProcessor()
    let clearsAttachments = name.hasSuffix("_cleared")
    @inline(never) func loop(_ count: Int) -> UInt64 {
        var checksum: UInt64 = 0
        for index in 0..<count {
            let fixture = values[index & 31]
            if clearsAttachments {
                // This control includes clearing and new attachment insertion.
                // It does not measure pixel-buffer allocation or pixel writes.
                CVBufferRemoveAllAttachments(fixture.buffer)
            }
            let result = processor.metadata(frame: fixture.frame, pixelBuffer: fixture.buffer)
            checksum &+= UInt64(result.masteringMetadata?.count ?? 0)
            checksum &+= UInt64(result.contentLightMetadata?.count ?? 0)
            checksum &+= UInt64(result.masteringMetadata?.first ?? 0)
            checksum &+= UInt64(result.contentLightMetadata?.last ?? 0)
        }
        return checksum
    }
    _ = autoreleasepool { loop(min(iterations, 10_000)) }
    let wallStart = DispatchTime.now().uptimeNanoseconds
    let cpuStart = cpuNanoseconds()
    // Temporary autorelease cleanup is included, without per-iteration pools.
    // The fixture ring and its final attachment values stay alive after timing.
    let checksum = autoreleasepool { loop(iterations) }
    let cpuElapsed = cpuNanoseconds() - cpuStart
    let wallElapsed = DispatchTime.now().uptimeNanoseconds - wallStart
    return Timing(case: name, iterations: iterations, wall_ns: wallElapsed,
                  cpu_ns: cpuElapsed, checksum: checksum)
}

@main
private enum Main {
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        if args == ["--verify"] {
            data = try encoder.encode(verify())
        } else {
            require(args.count == 4 && args[0] == "--case" && args[2] == "--iterations", "arguments")
            guard let count = Int(args[3]), count > 0 else { fatalError("iterations") }
            data = try encoder.encode(benchmark(args[1], iterations: count))
        }
        print(String(decoding: data, as: UTF8.self))
    }
}
