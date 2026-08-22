// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DeviceBridge",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "DeviceBridge",
            path: "Sources/DeviceBridge"
        )
    ]
)
