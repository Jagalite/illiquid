import CryptoKit
import Darwin
import Foundation
import Metal
@testable import PiPSubtitleUploadQualification

// Real Metal upload resources; rendering is checked separately from timing.
private struct ProbeFailure: Error { let message: String }

private func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw ProbeFailure(message: message) }
}

private func nanos(_ clock: clockid_t) throws -> UInt64 {
    var value = timespec()
    try require(clock_gettime(clock, &value) == 0, "clock_gettime failed")
    return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
}

private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func makeFrame(
    width: Int, height: Int, bgra: Bool = false, bitmapAtlas: Bool = false,
    seed: Int = 1, quads: Int = 8, shift: CGFloat = 0,
    canvas: CGSize = CGSize(width: 320, height: 180), rowPadding: Int = 0
) -> ASSPreparedSubtitleFrame {
    let bytesPerPixel = bgra ? 4 : 1
    let rowBytes = width * bytesPerPixel + rowPadding
    var pixels = Data(count: rowBytes * height)
    pixels.withUnsafeMutableBytes { raw in
        let bytes = raw.bindMemory(to: UInt8.self)
        for row in 0..<height {
            for column in 0..<(width * bytesPerPixel) {
                bytes[row * rowBytes + column] = bgra && column % 4 == 3
                    ? 255 : UInt8((column * 13 + row * 7 + seed * 19) & 255)
            }
        }
    }
    let sourceWidth = max(1, width / 4)
    let sourceHeight = max(1, height / 4)
    let regions = (0..<quads).map { index in
        ASSAtlasQuad(
            source: CGRect(
                x: (index % 4) * sourceWidth, y: ((index / 4) % 4) * sourceHeight,
                width: sourceWidth, height: sourceHeight
            ),
            destination: CGRect(
                x: CGFloat(10 + (index % 4) * 68) + shift,
                y: CGFloat(12 + ((index / 4) % 6) * 24), width: 60, height: 18
            ),
            color: 0xe0b06000 | UInt32((index * 11) & 127)
        )
    }
    return ASSPreparedSubtitleFrame(
        strategy: bgra ? .metalBGRA : .metalR8Atlas,
        canvasSize: canvas, textureSize: CGSize(width: width, height: height),
        bytesPerRow: rowBytes, pixels: pixels, quads: regions,
        metrics: ASSCompositionMetrics(
            imageCount: quads, copiedBytes: width * height * bytesPerPixel,
            uploadBytes: width * height * bytesPerPixel, drawCalls: 1,
            atlasWidth: width, atlasHeight: height
        ),
        usesBitmapAtlas: bitmapAtlas
    )
}

private func activePixels(
    _ upload: PiPSubtitleUploadCache.Upload, frame: ASSPreparedSubtitleFrame
) throws -> Data {
    let width = Int(frame.textureSize.width), height = Int(frame.textureSize.height)
    let bytesPerPixel = frame.strategy == .metalBGRA ? 4 : 1
    try require(upload.texture.width >= width && upload.texture.height >= height, "undersized texture")
    try require(upload.texture.pixelFormat == (bytesPerPixel == 4 ? .bgra8Unorm : .r8Unorm), "pixel format mismatch")
    let rowBytes = width * bytesPerPixel
    var pixels = Data(count: rowBytes * height)
    pixels.withUnsafeMutableBytes { bytes in
        upload.texture.getBytes(
            bytes.baseAddress!, bytesPerRow: rowBytes,
            from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0
        )
    }
    for row in 0..<height {
        let actual = pixels[(row * rowBytes)..<((row + 1) * rowBytes)]
        let expected = frame.pixels[(row * frame.bytesPerRow)..<(row * frame.bytesPerRow + rowBytes)]
        try require(actual.elementsEqual(expected), "active texture pixels differ at row \(row)")
    }
    return pixels
}

private func vertexBytes(_ upload: PiPSubtitleUploadCache.Upload) throws -> Data {
    // The production Metal shader declares float2 + float2 + float4 (32 bytes).
    let count = upload.vertexCount * 32
    try require(upload.vertexBuffer.length >= count, "undersized vertex buffer")
    return Data(bytes: upload.vertexBuffer.contents(), count: count)
}

private final class DrawVerifier {
    let device: any MTLDevice
    let queue: any MTLCommandQueue
    let textPipeline: any MTLRenderPipelineState
    let bitmapPipeline: any MTLRenderPipelineState
    let sampler: any MTLSamplerState

    init(device: any MTLDevice, shader: String) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw ProbeFailure(message: "no command queue") }
        self.queue = queue
        let library = try device.makeLibrary(source: shader, options: nil)
        guard let vertex = library.makeFunction(name: "pip_subtitle_vertex"),
              let text = library.makeFunction(name: "pip_subtitle_fragment"),
              let bitmap = library.makeFunction(name: "pip_bitmap_subtitle_fragment") else {
            throw ProbeFailure(message: "missing original PiP subtitle shaders")
        }
        func pipeline(_ fragment: any MTLFunction, premultiplied: Bool) throws -> any MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            descriptor.colorAttachments[0].isBlendingEnabled = true
            descriptor.colorAttachments[0].sourceRGBBlendFactor = premultiplied ? .one : .sourceAlpha
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        textPipeline = try pipeline(text, premultiplied: false)
        bitmapPipeline = try pipeline(bitmap, premultiplied: true)
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw ProbeFailure(message: "no sampler")
        }
        self.sampler = sampler
    }

    func draw(_ upload: PiPSubtitleUploadCache.Upload, frame: ASSPreparedSubtitleFrame) throws -> Data {
        let width = Int(frame.canvasSize.width), height = Int(frame.canvasSize.height)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget]
        guard let target = device.makeTexture(descriptor: descriptor),
              let command = queue.makeCommandBuffer() else { throw ProbeFailure(message: "draw setup failed") }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
            throw ProbeFailure(message: "draw encoder failed")
        }
        var viewport = SIMD2<Float>(Float(width), Float(height))
        encoder.setRenderPipelineState(frame.strategy == .metalBGRA ? bitmapPipeline : textPipeline)
        encoder.setVertexBuffer(upload.vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
        encoder.setFragmentTexture(upload.texture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: upload.vertexCount)
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        try require(command.status == .completed, "GPU draw did not complete: \(String(describing: command.error))")
        var pixels = Data(count: width * height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            target.getBytes(bytes.baseAddress!, bytesPerRow: width * 4,
                            from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        try require(pixels.enumerated().contains { $0.offset % 4 != 3 && $0.element != 0 }, "caption draw was empty")
        return pixels
    }
}

private struct VerificationStep {
    let name: String
    let frame: ASSPreparedSubtitleFrame?
    var invalidate = true
    var retire = false
}

private func verify(device: any MTLDevice, shader: String) throws -> [String: Any] {
    let small = makeFrame(width: 256, height: 256)
    let moved = makeFrame(width: 256, height: 256, seed: 2, shift: 7)
    let bgra = makeFrame(width: 192, height: 128, bgra: true, seed: 3)
    let steps = [
        VerificationStep(name: "first-caption", frame: small),
        VerificationStep(name: "unchanged-caption", frame: small, invalidate: false),
        VerificationStep(name: "same-size-new-pixels", frame: makeFrame(width: 256, height: 256, seed: 2)),
        VerificationStep(name: "geometry-only", frame: moved),
        VerificationStep(name: "new-canvas", frame: makeFrame(width: 256, height: 256, seed: 2, shift: 7,
                                                           canvas: CGSize(width: 640, height: 360))),
        VerificationStep(name: "texture-growth", frame: makeFrame(width: 1024, height: 1024, seed: 4)),
        VerificationStep(name: "texture-shrink", frame: small),
        VerificationStep(name: "quad-buffer-growth", frame: makeFrame(width: 256, height: 256, quads: 100)),
        VerificationStep(name: "quad-buffer-shrink", frame: makeFrame(width: 256, height: 256, quads: 2)),
        VerificationStep(name: "r8-to-bgra", frame: bgra),
        VerificationStep(name: "unchanged-bgra", frame: bgra, invalidate: false),
        VerificationStep(name: "bitmap-atlas", frame: makeFrame(width: 192, height: 128, bgra: true,
                                                              bitmapAtlas: true, seed: 3)),
        VerificationStep(name: "bgra-to-r8", frame: moved),
        VerificationStep(name: "padded-source-rows", frame: makeFrame(width: 65, height: 31, rowPadding: 13)),
        VerificationStep(name: "empty-caption-boundary", frame: nil),
        VerificationStep(name: "caption-after-empty", frame: small, invalidate: false),
        VerificationStep(name: "retired-source", frame: small, invalidate: false, retire: true),
        VerificationStep(name: "unchanged-new-source", frame: small, invalidate: false),
    ]
    let cache = PiPSubtitleUploadCache(device: device)
    let renderer = try DrawVerifier(device: device, shader: shader)
    var dirty = true
    var previous: PiPSubtitleUploadCache.Upload?
    var semantic: [[String: Any]] = []
    var counters: [[String: Any]] = []
    for step in steps {
        if step.retire { cache.retireSource(); dirty = true }
        if step.invalidate { cache.invalidate(); dirty = true }
        guard let frame = step.frame else {
            semantic.append(["step": step.name, "draw_calls": 0])
            continue
        }
        let upload = try cache.resources(for: frame)
        let expectedUpload = benchmarkVariant == "baseline" || dirty
        try require(upload.didUpload == expectedUpload, "wrong upload state: \(step.name)")
        try require(upload.vertexCount == frame.quads.count * 6, "wrong vertex count: \(step.name)")
        let expectedPixelBytes = Int(frame.textureSize.width * frame.textureSize.height) * (frame.strategy == .metalBGRA ? 4 : 1)
        try require(upload.textureUploadBytes == (expectedUpload ? expectedPixelBytes : 0), "wrong pixel upload bytes")
        try require(upload.vertexUploadBytes == (expectedUpload ? upload.vertexCount * 32 : 0), "wrong vertex upload bytes")
        if let previous {
            if !dirty {
                try require(upload.texture === previous.texture && upload.vertexBuffer === previous.vertexBuffer,
                            "unchanged frame changed resource identity")
            }
            if step.retire {
                try require(upload.texture !== previous.texture && upload.vertexBuffer !== previous.vertexBuffer,
                            "retired source reused old resources")
            }
        }
        let pixels = try activePixels(upload, frame: frame)
        let vertices = try vertexBytes(upload)
        let output = try renderer.draw(upload, frame: frame)
        semantic.append([
            "step": step.name, "draw_calls": 1, "active_pixels_sha256": digest(pixels),
            "vertex_bytes_sha256": digest(vertices), "draw_pixels_sha256": digest(output),
            "vertex_count": upload.vertexCount, "texture_width": upload.texture.width,
            "texture_height": upload.texture.height, "pixel_format": upload.texture.pixelFormat.rawValue,
            "vertex_buffer_length": upload.vertexBuffer.length, "bitmap_atlas": frame.usesBitmapAtlas,
        ])
        counters.append(["step": step.name, "did_upload": upload.didUpload,
                         "texture_upload_bytes": upload.textureUploadBytes,
                         "vertex_upload_bytes": upload.vertexUploadBytes])
        dirty = false
        previous = upload
    }
    return ["mode": "verify", "variant": benchmarkVariant, "device": device.name,
            "semantic": semantic, "counters": counters, "steps": steps.count,
            "rendered_draw_calls": semantic.reduce(0) { $0 + ($1["draw_calls"] as? Int ?? 0) }]
}

private func benchmark(device: any MTLDevice, workload: String, count: Int) throws -> [String: Any] {
    let parts = workload.split(separator: "-")
    try require(parts.count == 3 && ["static", "changing"].contains(String(parts[2])), "unknown workload")
    let bgra = parts[0] == "bgra"
    let dimension: Int
    switch String(parts[1]) {
    case "64k": dimension = bgra ? 128 : 256
    case "1m": dimension = bgra ? 512 : 1024
    case "4m": dimension = bgra ? 1024 : 2048
    default: throw ProbeFailure(message: "unknown atlas size")
    }
    let changing = parts[2] == "changing"
    let frames = [
        makeFrame(width: dimension, height: dimension, bgra: bgra),
        makeFrame(width: dimension, height: dimension, bgra: bgra, seed: 2, shift: 1),
    ]
    let cache = PiPSubtitleUploadCache(device: device)
    for index in 0..<32 {
        if changing { cache.invalidate() }
        withExtendedLifetime(try cache.resources(for: frames[changing ? index % 2 : 0])) {}
    }
    cache.invalidate()
    var last = try cache.resources(for: frames[0])
    var uploads = 0, textureBytes = 0, bufferBytes = 0, vertexCountSum = 0
    let cpuStart = try nanos(CLOCK_PROCESS_CPUTIME_ID)
    let wallStart = try nanos(CLOCK_MONOTONIC_RAW)
    for index in 0..<count {
        if changing { cache.invalidate() }
        last = try cache.resources(for: frames[changing ? index % 2 : 0])
        uploads += last.didUpload ? 1 : 0
        textureBytes += last.textureUploadBytes
        bufferBytes += last.vertexUploadBytes
        vertexCountSum += last.vertexCount
    }
    let wall = try nanos(CLOCK_MONOTONIC_RAW) - wallStart
    let cpu = try nanos(CLOCK_PROCESS_CPUTIME_ID) - cpuStart
    let expectedUploads = benchmarkVariant == "baseline" || changing ? count : 0
    let final = frames[changing ? (count - 1) % 2 : 0]
    let bytesPerFrame = dimension * dimension * (bgra ? 4 : 1)
    try require(uploads == expectedUploads, "timed upload count differs")
    try require(textureBytes == expectedUploads * bytesPerFrame, "timed texture bytes differ")
    try require(bufferBytes == expectedUploads * final.quads.count * 6 * 32, "timed vertex bytes differ")
    try require(vertexCountSum == count * final.quads.count * 6, "timed vertex count differs")
    let pixels = try activePixels(last, frame: final)
    let vertices = try vertexBytes(last)
    return [
        "mode": "benchmark", "variant": benchmarkVariant, "workload": workload,
        "iterations": count, "wall_ns": wall, "cpu_ns": cpu, "device": device.name,
        "atlas_bytes": bytesPerFrame, "uploads": uploads, "texture_upload_bytes": textureBytes,
        "vertex_upload_bytes": bufferBytes, "vertex_count_sum": vertexCountSum,
        "timed_draw_calls": 0, "active_pixels_sha256": digest(pixels),
        "vertex_bytes_sha256": digest(vertices), "vertex_count": last.vertexCount,
        "texture_width": last.texture.width, "texture_height": last.texture.height,
        "scope": "Primed Metal upload-resource calls and counter collection; no timed GPU draws",
    ]
}

@main enum Main {
    static func main() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw ProbeFailure(message: "A native Metal device is required")
        }
        let args = CommandLine.arguments
        let result: [String: Any]
        if args.count == 3, args[1] == "verify" {
            result = try verify(device: device, shader: String(contentsOfFile: args[2], encoding: .utf8))
        } else if args.count == 4, args[1] == "benchmark", let count = Int(args[3]),
                  (2...20_000_000).contains(count), count % 2 == 0 {
            result = try benchmark(device: device, workload: args[2], count: count)
        } else {
            throw ProbeFailure(message: "usage: probe verify shader-path | benchmark workload even-iterations")
        }
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
    }
}
