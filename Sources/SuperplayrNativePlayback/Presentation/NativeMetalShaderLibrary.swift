import Foundation
import Metal

enum NativeMetalShaderLibrary {
    static func load(device: any MTLDevice) throws -> any MTLLibrary {
        let resourceBundle: Bundle
        let isPackagedApplication: Bool
        if let packagedResources = Bundle.main.resourceURL,
           let packagedBundle = Bundle(
               url: packagedResources.appendingPathComponent(
                   "Superplayr_SuperplayrNativePlayback.bundle",
                   isDirectory: true
               )
           ) {
            resourceBundle = packagedBundle
            isPackagedApplication = Bundle.main.bundleURL.pathExtension == "app"
        } else {
            resourceBundle = .module
            isPackagedApplication = false
        }

        // Distribution builds add default.metallib to this resource bundle.
        // Plain SwiftPM builds retain the source fallback for tests and local
        // development because `swift build` copies, but does not compile, Metal.
        // Packaging can leave a compiled library in the shared SwiftPM build
        // bundle. Tests must compile the current source, not silently use that
        // stale artifact after a shader edit.
        if isPackagedApplication,
           let library = try? device.makeDefaultLibrary(bundle: resourceBundle) {
            return library
        }
        guard let sourceURL = resourceBundle.url(
            forResource: "NativePlaybackShaders",
            withExtension: "metal"
        ) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        return try device.makeLibrary(source: source, options: nil)
    }
}
