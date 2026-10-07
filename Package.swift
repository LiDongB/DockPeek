// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DockPeek",
    platforms: [
        // ScreenCaptureKit single-window capture (SCScreenshotManager) needs macOS 14+.
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "DockPeek",
            path: "Sources/DockPeek",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            // Keep the deployment target at 14, but opt into the UI of the SDK we build with.
            // SwiftPM's Xcode build engine otherwise stamps both minOS and SDK as 14.
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-platform_version", "-Xlinker", "macos",
                              "-Xlinker", "14.0", "-Xlinker", "27.0"])
            ]
        )
    ]
)
