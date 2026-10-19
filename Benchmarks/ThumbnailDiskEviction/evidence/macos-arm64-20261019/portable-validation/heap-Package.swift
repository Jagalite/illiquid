// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "ThumbnailDiskEvictionPortableTests",
    targets: [
        .target(name: "IlliquidNativePlayback"),
        .testTarget(name: "IlliquidNativePlaybackTests", dependencies: ["IlliquidNativePlayback"]),
    ]
)
