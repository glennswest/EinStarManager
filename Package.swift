// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "EinStarManager",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "EinStarManager",
            path: "Sources/EinStarManager"
        )
    ]
)
