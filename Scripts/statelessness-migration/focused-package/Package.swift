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
            revision: "ef6923412ebb38dc14fac58fcfea9404864c9f63"
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
