// swift-tools-version: 6.1
// Focused harness for the FFmpeg-free state-space targets of the Illiquid
// worktree. Target sources are symlinks; the dependency pin matches Illiquid.
import PackageDescription

let package = Package(
    name: "IlliquidStateSpaceFocused",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(
            url: "https://github.com/Jagalite/statelessness.git",
            revision: "3fbdca7c49be3cf32da613f887a7f149e0b97087"
        ),
    ],
    targets: [
        .target(name: "IlliquidCore", path: "Sources/IlliquidCore"),
        .target(name: "IlliquidPlaybackCore", dependencies: ["IlliquidCore"], path: "Sources/IlliquidPlaybackCore"),
        .target(
            name: "IlliquidPlaybackStateSpace",
            dependencies: ["IlliquidPlaybackCore", .product(name: "Statelessness", package: "statelessness")],
            path: "Sources/IlliquidPlaybackStateSpace"
        ),
        .testTarget(
            name: "IlliquidPlaybackStateSpaceTests",
            dependencies: ["IlliquidPlaybackStateSpace", .product(name: "Statelessness", package: "statelessness")],
            path: "Tests/IlliquidPlaybackStateSpaceTests",
            exclude: ["Fixtures"]
        ),
    ]
)
