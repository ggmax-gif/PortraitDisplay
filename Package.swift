// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PortraitDisplay",
    platforms: [.macOS(.v13)],
    targets: [
        // Declarations for Apple's private CGVirtualDisplay classes (live in CoreGraphics).
        .target(
            name: "CGVirtualDisplayPrivate",
            path: "Sources/CGVirtualDisplayPrivate",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("CoreGraphics"),
            ]
        ),
        .executableTarget(
            name: "PortraitHost",
            dependencies: ["CGVirtualDisplayPrivate"],
            path: "Sources/PortraitHost",
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("CoreImage"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("Network"),
            ]
        ),
    ]
)
