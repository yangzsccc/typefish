// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TypeFish",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "TypeFish",
            path: "Sources/TypeFish",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("AVFoundation"),
            ]
        )
    ]
)
