// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "Superplayr",
    platforms: [
        .macOS("26.0"),
    ],
    products: [
        .executable(name: "Superplayr", targets: ["SuperplayrApp"]),
        .executable(name: "SuperplayrPlaybackStress", targets: ["SuperplayrPlaybackStress"]),
        .executable(name: "SuperplayrRenderProfile", targets: ["SuperplayrRenderProfile"]),
        .executable(name: "SuperplayrStateSpaceExplorer", targets: ["SuperplayrStateSpaceExplorer"]),
        .executable(
            name: "SuperplayrDifferentialHarness",
            targets: ["SuperplayrDifferentialHarness"]
        ),
        .library(name: "SuperplayrCore", targets: ["SuperplayrCore"]),
        .library(name: "SuperplayrPlaybackCore", targets: ["SuperplayrPlaybackCore"]),
        .library(name: "SuperplayrPlaybackStateSpace", targets: ["SuperplayrPlaybackStateSpace"]),
        .library(name: "SuperplayrPlayback", targets: ["SuperplayrPlayback"]),
        .library(name: "SuperplayrNativePlayback", targets: ["SuperplayrNativePlayback"]),
        .library(name: "SuperplayrPlayer", targets: ["SuperplayrPlayer"]),
    ],
    dependencies: [
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
            name: "SuperplayrCore",
            path: "Sources/SuperplayrCore"
        ),
        .target(
            name: "SuperplayrPlaybackCore",
            dependencies: ["SuperplayrCore"],
            path: "Sources/SuperplayrPlaybackCore"
        ),
        .target(
            name: "SuperplayrPlaybackStateSpace",
            dependencies: ["SuperplayrPlaybackCore"],
            path: "Sources/SuperplayrPlaybackStateSpace"
        ),
        .target(
            name: "SuperplayrPlayback",
            dependencies: ["SuperplayrCore", "SuperplayrPlaybackCore"],
            path: "Sources/SuperplayrPlayback",
            linkerSettings: [
                .linkedFramework("AppKit"),
            ]
        ),
        .target(
            name: "SuperplayrNativePlayback",
            dependencies: [
                "CFFmpeg",
                "CLibass",
                "CNativeAudio",
                "SuperplayrCore",
                "SuperplayrPlaybackCore",
                "SuperplayrPlayback",
            ],
            path: "Sources/SuperplayrNativePlayback",
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
            name: "SuperplayrPlayer",
            dependencies: [
                "SuperplayrCore",
                "SuperplayrPlaybackCore",
                "SuperplayrPlayback",
                "SuperplayrNativePlayback",
            ],
            path: "Sources/SuperplayrPlayer",
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        .executableTarget(
            name: "SuperplayrApp",
            dependencies: ["SuperplayrCore", "SuperplayrPlayer"],
            path: "Sources/SuperplayrApp",
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
            name: "SuperplayrArchitectureCheck",
            dependencies: ["SuperplayrPlayer", "SuperplayrPlaybackCore"],
            path: "Validation/SuperplayrArchitectureCheck"
        ),
        .executableTarget(
            name: "SuperplayrRenderProfile",
            dependencies: ["SuperplayrCore", "SuperplayrPlayback", "SuperplayrNativePlayback"],
            path: "Validation/SuperplayrRenderProfile",
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        .executableTarget(
            name: "SuperplayrPlaybackStress",
            dependencies: [
                "SuperplayrCore",
                "SuperplayrPlayback",
                "SuperplayrNativePlayback",
                "SuperplayrPlayer",
            ],
            path: "Validation/SuperplayrPlaybackStress",
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        .executableTarget(
            name: "SuperplayrDifferentialHarness",
            dependencies: ["SuperplayrNativePlayback"],
            path: "Validation/SuperplayrDifferentialHarness"
        ),
        .executableTarget(
            name: "SuperplayrStateSpaceExplorer",
            dependencies: ["SuperplayrPlaybackStateSpace"],
            path: "Validation/SuperplayrStateSpaceExplorer"
        ),
        .testTarget(
            name: "SuperplayrPlaybackCoreTests",
            dependencies: [
                "SuperplayrPlaybackCore",
                .product(name: "Testing", package: "swift-testing"),
            ],
            path: "Tests/SuperplayrPlaybackCoreTests"
        ),
        .testTarget(
            name: "SuperplayrPlaybackStateSpaceTests",
            dependencies: [
                "SuperplayrPlaybackStateSpace",
                .product(name: "Testing", package: "swift-testing"),
            ],
            path: "Tests/SuperplayrPlaybackStateSpaceTests"
        ),
        .testTarget(
            name: "SuperplayrCoreTests",
            dependencies: [
                "SuperplayrCore",
                .product(name: "Testing", package: "swift-testing"),
            ],
            path: "Tests/SuperplayrCoreTests"
        ),
        .testTarget(
            name: "SuperplayrNativePlaybackTests",
            dependencies: [
                "CFFmpeg",
                "SuperplayrNativePlayback",
                .product(name: "Testing", package: "swift-testing"),
            ],
            path: "Tests/SuperplayrNativePlaybackTests"
        ),
        .testTarget(
            name: "SuperplayrPlaybackTests",
            dependencies: [
                "SuperplayrPlayback",
                .product(name: "Testing", package: "swift-testing"),
            ],
            path: "Tests/SuperplayrPlaybackTests"
        ),
        .testTarget(
            name: "SuperplayrPlayerTests",
            dependencies: [
                "SuperplayrPlayer",
                "SuperplayrPlaybackCore",
                .product(name: "Testing", package: "swift-testing"),
            ],
            path: "Tests/SuperplayrPlayerTests"
        ),
        .testTarget(
            name: "SuperplayrAppTests",
            dependencies: [
                "SuperplayrApp",
                "SuperplayrPlayback",
                "SuperplayrPlayer",
                .product(name: "Testing", package: "swift-testing"),
            ],
            path: "Tests/SuperplayrAppTests",
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
