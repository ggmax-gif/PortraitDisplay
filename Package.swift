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
        // Shared with the iPad app (iPad/project.yml builds the same folder as a framework): message
        // framing, the direct Wi-Fi TLS setup and pairing, and the gesture decisions.
        .target(
            name: "Shared",
            path: "Sources/Shared",
            linkerSettings: [.linkedFramework("Network")]
        ),
        .executableTarget(
            name: "PortraitHost",
            dependencies: ["CGVirtualDisplayPrivate", "Shared"],
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
        // Run with Xcode's toolchain (the Command Line Tools have no XCTest):
        // DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
        .testTarget(name: "SharedTests", dependencies: ["Shared"], path: "Tests/SharedTests"),
        .testTarget(name: "PortraitHostTests", dependencies: ["PortraitHost"], path: "Tests/PortraitHostTests"),
        .testTarget(name: "PortraitMenuTests", dependencies: ["PortraitMenu"], path: "Tests/PortraitMenuTests"),
    ]
)
