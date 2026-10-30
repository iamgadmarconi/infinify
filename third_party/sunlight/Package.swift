// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sunlight",
    platforms: [.macOS(.v15)],
    products: [
        // The app is Sunlight; its module keeps the name it had as Canvas.
        .executable(name: "Sunlight", targets: ["Canvas"])
    ],
    dependencies: [
        // Updates. scripts/package.sh embeds the framework in Contents/Frameworks.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.4"),
    ],
    targets: [
        .executableTarget(
            name: "Canvas",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Canvas",
            swiftSettings: [
                .swiftLanguageMode(.v5)  // strict concurrency as warnings, not errors
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("IOSurface"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("CoreImage"),
                .linkedFramework("Metal"),
                .linkedFramework("PhotosUI"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("AVFoundation"),
                // Sparkle.framework, in the app bundle.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        .testTarget(name: "CanvasTests", dependencies: ["Canvas"])
    ]
)
