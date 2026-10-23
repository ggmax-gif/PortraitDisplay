// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PortraitDisplay",
    platforms: [.macOS("15.0")],  // kSecImportToMemoryOnly
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
                .linkedFramework("VideoToolbox"),
                .linkedFramework("Security"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("Network"),
            ]
        ),
        // Menu bar app: starts and stops PortraitHost. Bundle it with scripts/make-app.sh.
        .executableTarget(
            name: "PortraitMenu",
            path: "Sources/PortraitMenu",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("CoreImage"),
                .linkedFramework("SwiftUI"),
            ]
        ),
    ]
)
