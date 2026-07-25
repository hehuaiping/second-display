// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "SecondDisplay",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SecondDisplayMacApp", targets: ["SecondDisplayMacApp"]),
        .library(name: "SecondDisplayCore", targets: ["SecondDisplayCore"]),
        .library(name: "SharedProtocol", targets: ["SharedProtocol"]),
        .library(name: "VirtualDisplayCore", targets: ["VirtualDisplayCore"]),
        .library(name: "CapturePipeline", targets: ["CapturePipeline"]),
        .library(name: "TransportCore", targets: ["TransportCore"]),
        .library(name: "P3HostCore", targets: ["P3HostCore"]),
        .executable(name: "MediaVectorGenerator", targets: ["MediaVectorGenerator"]),
        .executable(name: "P3PoCHost", targets: ["P3PoCHost"]),
    ],
    targets: [
        .target(
            name: "SecondDisplayCore",
            path: "macos/SecondDisplayCore"
        ),
        .target(
            name: "SharedProtocol",
            dependencies: ["SecondDisplayCore"],
            path: "macos/SharedProtocol"
        ),
        .target(
            name: "VirtualDisplayCore",
            dependencies: ["SecondDisplayCore", "PrivateAPIShim"],
            path: "macos/VirtualDisplayCore/Public",
            resources: [.process("Resources")]
        ),
        .target(
            name: "CapturePipeline",
            dependencies: ["SecondDisplayCore", "SharedProtocol", "VirtualDisplayCore"],
            path: "macos/CapturePipeline",
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("VideoToolbox"),
            ]
        ),
        .target(
            name: "TransportCore",
            dependencies: ["SecondDisplayCore", "SharedProtocol"],
            path: "macos/TransportCore",
            linkerSettings: [
                .linkedFramework("Network"),
                .linkedFramework("Security"),
            ]
        ),
        .executableTarget(
            name: "MediaVectorGenerator",
            dependencies: ["CapturePipeline", "SecondDisplayCore"],
            path: "tools/media-vector-generator"
        ),
        .executableTarget(
            name: "P3PoCHost",
            dependencies: ["P3HostCore", "SecondDisplayCore"],
            path: "tools/p3-poc-host"
        ),
        .target(
            name: "P3HostCore",
            dependencies: [
                "SecondDisplayCore", "SharedProtocol", "VirtualDisplayCore", "CapturePipeline",
                "TransportCore",
            ],
            path: "macos/P3HostCore",
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        .target(
            name: "PrivateAPIShim",
            path: "macos/VirtualDisplayCore/PrivateAPIShim",
            publicHeadersPath: "include",
            cSettings: [.unsafeFlags(["-fobjc-arc"])],
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("CoreGraphics"),
            ]
        ),
        .executableTarget(
            name: "SecondDisplayMacApp",
            dependencies: [
                "SecondDisplayCore", "SharedProtocol", "VirtualDisplayCore", "CapturePipeline",
                "TransportCore",
                "P3HostCore",
            ],
            path: "macos/SecondDisplayMacApp"
        ),
        .testTarget(
            name: "SecondDisplayMacTests",
            dependencies: [
                "SecondDisplayCore", "SharedProtocol", "VirtualDisplayCore", "CapturePipeline",
                "TransportCore",
                "P3HostCore",
            ],
            path: "macos/SecondDisplayMacTests"
        ),
    ]
)
