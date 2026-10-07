// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "Illiquid",
    platforms: [
        .macOS("26.0"),
    ],
    products: [
        .executable(name: "Illiquid", targets: ["IlliquidApp"]),
        .executable(name: "IlliquidPlaybackStress", targets: ["IlliquidPlaybackStress"]),
        .executable(name: "IlliquidRenderProfile", targets: ["IlliquidRenderProfile"]),
        .executable(name: "IlliquidStateSpaceExplorer", targets: ["IlliquidStateSpaceExplorer"]),
        .executable(
            name: "IlliquidDifferentialHarness",
            targets: ["IlliquidDifferentialHarness"]
        ),
        .library(name: "IlliquidCore", targets: ["IlliquidCore"]),
        .library(name: "IlliquidPlaybackCore", targets: ["IlliquidPlaybackCore"]),
        .library(name: "IlliquidPlaybackStateSpace", targets: ["IlliquidPlaybackStateSpace"]),
        .library(name: "IlliquidPlayback", targets: ["IlliquidPlayback"]),
        .library(name: "IlliquidNativePlayback", targets: ["IlliquidNativePlayback"]),
        .library(name: "IlliquidPlayer", targets: ["IlliquidPlayer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.10.0"),
        .package(
            url: "https://github.com/swiftlang/swift-testing.git",
            revision: "swift-6.3.2-RELEASE"
        ),
    ],
    targets: [
        .systemLibrary(
            name: "CFFmpeg",
            path: "Sources/CFFmpeg",
            pkgConfig: "libavformat",
            providers: [
                .brew(["ffmpeg"]),
            ]
        ),
        .systemLibrary(
            name: "CLibass",
            path: "Sources/CLibass",
            pkgConfig: "libass",
            providers: [
                .brew(["libass"]),
            ]
        ),
        .target(
            name: "CNativeAudio",
            path: "Sources/CNativeAudio",
            publicHeadersPath: "include",
            linkerSettings: [.linkedFramework("AVFoundation")]
        ),
        .target(
            name: "IlliquidCore",
            path: "Sources/IlliquidCore"
        ),
        .target(
            name: "IlliquidPlaybackCore",
            dependencies: ["IlliquidCore"],
            path: "Sources/IlliquidPlaybackCore"
        ),
        .target(
            name: "IlliquidPlaybackStateSpace",
            dependencies: ["IlliquidPlaybackCore"],
            path: "Sources/IlliquidPlaybackStateSpace"
        ),
        .target(
            name: "IlliquidPlayback",
            dependencies: ["IlliquidCore", "IlliquidPlaybackCore"],
            path: "Sources/IlliquidPlayback",
            linkerSettings: [
                .linkedFramework("AppKit"),
            ]
        ),
        .target(
            name: "IlliquidNativePlayback",
            dependencies: [
                "CFFmpeg",
                "CLibass",
                "CNativeAudio",
                "IlliquidCore",
                "IlliquidPlaybackCore",
                "IlliquidPlayback",
            ],
            path: "Sources/IlliquidNativePlayback",
            resources: [
                .process("Resources"),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AVKit"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("VideoToolbox"),
            ]
        ),
        .target(
            name: "IlliquidPlayer",
            dependencies: [
                "IlliquidCore",
                "IlliquidPlaybackCore",
                "IlliquidPlayback",
                "IlliquidNativePlayback",
            ],
            path: "Sources/IlliquidPlayer",
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        .executableTarget(
            name: "IlliquidApp",
            dependencies: ["IlliquidCore", "IlliquidPlayer", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/IlliquidApp",
            resources: [
                .process("Resources"),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVKit"),
                .linkedFramework("MediaPlayer"),
            ]
        ),
        .executableTarget(
            name: "IlliquidArchitectureCheck",
            dependencies: ["IlliquidPlayer", "IlliquidPlaybackCore"],
            path: "Validation/IlliquidArchitectureCheck"
        ),
        .executableTarget(
            name: "IlliquidRenderProfile",
            dependencies: ["IlliquidCore", "IlliquidPlayback", "IlliquidNativePlayback"],
            path: "Validation/IlliquidRenderProfile",
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        .executableTarget(
            name: "IlliquidPlaybackStress",
            dependencies: [
                "IlliquidCore",
                "IlliquidPlayback",
                "IlliquidNativePlayback",
                "IlliquidPlayer",
            ],
            path: "Validation/IlliquidPlaybackStress",
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        .executableTarget(
            name: "IlliquidDifferentialHarness",
            dependencies: ["IlliquidNativePlayback"],
            path: "Validation/IlliquidDifferentialHarness"
        ),
        .executableTarget(
            name: "IlliquidStateSpaceExplorer",
            dependencies: ["IlliquidPlaybackStateSpace"],
            path: "Validation/IlliquidStateSpaceExplorer"
        ),
        .testTarget(
            name: "IlliquidPlaybackCoreTests",
            dependencies: [
                "IlliquidPlaybackCore",
                .product(name: "Testing", package: "swift-testing"),
            ],
            path: "Tests/IlliquidPlaybackCoreTests"
        ),
        .testTarget(
            name: "IlliquidPlaybackStateSpaceTests",
            dependencies: [
                "IlliquidPlaybackStateSpace",
                .product(name: "Testing", package: "swift-testing"),
            ],
            path: "Tests/IlliquidPlaybackStateSpaceTests"
        ),
        .testTarget(
            name: "IlliquidCoreTests",
            dependencies: [
                "IlliquidCore",
                .product(name: "Testing", package: "swift-testing"),
            ],
            path: "Tests/IlliquidCoreTests"
        ),
        .testTarget(
            name: "IlliquidNativePlaybackTests",
            dependencies: [
                "CFFmpeg",
                "IlliquidNativePlayback",
                .product(name: "Testing", package: "swift-testing"),
            ],
            path: "Tests/IlliquidNativePlaybackTests"
        ),
        .testTarget(
            name: "IlliquidPlaybackTests",
            dependencies: [
                "IlliquidPlayback",
                .product(name: "Testing", package: "swift-testing"),
            ],
            path: "Tests/IlliquidPlaybackTests"
        ),
        .testTarget(
            name: "IlliquidPlayerTests",
            dependencies: [
                "IlliquidPlayer",
                "IlliquidPlaybackCore",
                .product(name: "Testing", package: "swift-testing"),
            ],
            path: "Tests/IlliquidPlayerTests"
        ),
        .testTarget(
            name: "IlliquidAppTests",
            dependencies: [
                "IlliquidApp",
                "IlliquidPlayback",
                "IlliquidPlayer",
                .product(name: "Testing", package: "swift-testing"),
            ],
            path: "Tests/IlliquidAppTests",
            linkerSettings: [
                .unsafeFlags([
                    "-L/Library/Developer/CommandLineTools/Library/Developer/usr/lib",
                    "-Xlinker",
                    "-rpath",
                    "-Xlinker",
                    "/Library/Developer/CommandLineTools/Library/Developer/usr/lib",
                ]),
            ]
        ),
    ]
)
