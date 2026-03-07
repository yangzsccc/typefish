// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TypeFish",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "ObjCExceptionCatcher",
            path: "Sources/ObjCExceptionCatcher",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "TypeFish",
            dependencies: ["ObjCExceptionCatcher"],
            path: "Sources/TypeFish",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("AVFoundation"),
            ]
        )
    ]
)
