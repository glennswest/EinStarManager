// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "EinStarManager",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "RigilKit", targets: ["RigilKit"]),
    ],
    targets: [
        .target(
            name: "RigilKit",
            path: "Sources/RigilKit"
        ),
        .executableTarget(
            name: "EinStarManager",
            dependencies: ["RigilKit"],
            path: "Sources/EinStarManager"
        ),
    ]
)
