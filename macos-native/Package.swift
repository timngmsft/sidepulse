// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SidePulseNative",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "SidePulseCore", targets: ["SidePulseCore"]),
        .executable(name: "SidePulseHook", targets: ["SidePulseHook"]),
        .executable(name: "SidePulseNative", targets: ["SidePulseNative"])
    ],
    targets: [
        .target(name: "SidePulseCore"),
        .executableTarget(name: "SidePulseHook", dependencies: ["SidePulseCore"]),
        .executableTarget(
            name: "SidePulseNative", dependencies: ["SidePulseCore"],
            linkerSettings: [
                .linkedFramework("AppKit"), .linkedFramework("SwiftUI"),
                .linkedFramework("IOKit"), .linkedFramework("DiskArbitration"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .testTarget(name: "SidePulseCoreTests", dependencies: ["SidePulseCore"])
    ],
    swiftLanguageModes: [.v5]
)
