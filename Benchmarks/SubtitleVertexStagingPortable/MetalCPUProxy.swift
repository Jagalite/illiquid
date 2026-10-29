import Foundation

// Named stand-ins solely for the portable CPU proxy. These declarations let the
// production upload method bodies and the existing driver compile unchanged.
// They do not reproduce Metal allocation, Objective-C dispatch, synchronization,
// shader behavior or GPU resource lifetime. The native workflow covers those.
enum MTLPixelFormat: Sendable {
    case r8Unorm
    case bgra8Unorm
    case bgra8Unorm_srgb
}
enum MTLTextureUsage: Sendable { case shaderRead }
enum MTLStorageMode: Sendable { case shared }
enum MTLResourceOptions: Sendable { case storageModeShared }

protocol MTLBuffer: AnyObject {
    var length: Int { get }
    func contents() -> UnsafeMutableRawPointer
}

protocol MTLTexture: AnyObject {
    var width: Int { get }
    var height: Int { get }
}

protocol MTLDevice: AnyObject {
    func makeBuffer(length: Int, options: MTLResourceOptions) -> (any MTLBuffer)?
    func makeTexture(descriptor: MTLTextureDescriptor) -> (any MTLTexture)?
}

final class MTLTextureDescriptor {
    let pixelFormat: MTLPixelFormat
    let width: Int
    let height: Int
    var usage: MTLTextureUsage = .shaderRead
    var storageMode: MTLStorageMode = .shared

    private init(pixelFormat: MTLPixelFormat, width: Int, height: Int) {
        self.pixelFormat = pixelFormat
        self.width = width
        self.height = height
    }

    static func texture2DDescriptor(
        pixelFormat: MTLPixelFormat, width: Int, height: Int, mipmapped: Bool
    ) -> MTLTextureDescriptor {
        precondition(!mipmapped)
        return MTLTextureDescriptor(pixelFormat: pixelFormat, width: width, height: height)
    }
}

private final class RawProxyBuffer: MTLBuffer {
    let length: Int
    private let storage: UnsafeMutableRawPointer

    init(length: Int) {
        precondition(length > 0)
        self.length = length
        storage = .allocate(byteCount: length, alignment: 64)
    }

    deinit { storage.deallocate() }

    func contents() -> UnsafeMutableRawPointer { storage }
}

private final class RawProxyTexture: MTLTexture {
    let width: Int
    let height: Int

    init(descriptor: MTLTextureDescriptor) {
        width = descriptor.width
        height = descriptor.height
    }
}

private final class RawProxyDevice: MTLDevice {
    func makeBuffer(length: Int, options: MTLResourceOptions) -> (any MTLBuffer)? {
        guard length > 0 else { return nil }
        return RawProxyBuffer(length: length)
    }

    func makeTexture(descriptor: MTLTextureDescriptor) -> (any MTLTexture)? {
        guard descriptor.width > 0, descriptor.height > 0 else { return nil }
        return RawProxyTexture(descriptor: descriptor)
    }
}

func MTLCreateSystemDefaultDevice() -> (any MTLDevice)? { RawProxyDevice() }
