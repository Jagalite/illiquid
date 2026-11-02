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
            revision: "20fc035ec3c91a69934657909b3c044cec86a07e"
        ),
    ],
    targets: [
        .target(name: "IlliquidCore", path: "Sources/IlliquidCore"),
        .target(
            name: "IlliquidPlaybackModel",
            dependencies: ["IlliquidCore", .product(name: "Statelessness", package: "statelessness")],
            path: "Sources/IlliquidPlaybackModel"
        ),
        .target(
            name: "IlliquidPlaybackStateSpace",
            dependencies: ["IlliquidPlaybackModel", .product(name: "Statelessness", package: "statelessness")],
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
