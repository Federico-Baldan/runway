// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Runway",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Runway",
            path: "Sources/Runway"
        )
    ]
)
