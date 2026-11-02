// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "LibassPositionReuseLinuxExploration",
    products: [
        .executable(name: "LibassBaseline", targets: ["LibassBaseline"]),
        .executable(name: "LibassCandidate", targets: ["LibassCandidate"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "3.12.3"),
        .package(url: "https://github.com/apple/swift-asn1.git", exact: "1.3.1"),
    ],
    targets: [
        .systemLibrary(name: "CLibass", pkgConfig: "libass"),
        .target(name: "IlliquidNativePlaybackBaseline", dependencies: ["CLibass", .product(name: "Crypto", package: "swift-crypto")], swiftSettings: [.unsafeFlags(["-enable-testing", "-warnings-as-errors"])]),
        .executableTarget(name: "LibassBaseline", dependencies: ["IlliquidNativePlaybackBaseline", .product(name: "Crypto", package: "swift-crypto")], swiftSettings: [.unsafeFlags(["-warnings-as-errors"])]),
        .testTarget(name: "IlliquidNativePlaybackBaselineTests", dependencies: ["IlliquidNativePlaybackBaseline", .product(name: "Crypto", package: "swift-crypto")], swiftSettings: [.unsafeFlags(["-warnings-as-errors"])]),
        .target(name: "IlliquidNativePlaybackCandidate", dependencies: ["CLibass", .product(name: "Crypto", package: "swift-crypto")], swiftSettings: [.unsafeFlags(["-enable-testing", "-warnings-as-errors"])]),
        .executableTarget(name: "LibassCandidate", dependencies: ["IlliquidNativePlaybackCandidate", .product(name: "Crypto", package: "swift-crypto")], swiftSettings: [.unsafeFlags(["-warnings-as-errors"]), .define("POSITION_REUSE")]),
        .testTarget(name: "IlliquidNativePlaybackCandidateTests", dependencies: ["IlliquidNativePlaybackCandidate", .product(name: "Crypto", package: "swift-crypto")], swiftSettings: [.unsafeFlags(["-warnings-as-errors"])])
    ],
    swiftLanguageModes: [.v6]
)
