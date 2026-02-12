// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "WindowKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "WindowKit",
            targets: ["WindowKit"]
        ),
    ],
    targets: [
        .target(
            name: "WindowKit",
            dependencies: [],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("CoreGraphics"),
            ]
        ),
        .testTarget(
            name: "WindowKitTests",
            dependencies: ["WindowKit"]
        ),
    ]
)
