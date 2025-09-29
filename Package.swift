// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "StageManager",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "StageManager", targets: ["StageManager"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "StageManager",
            dependencies: [],
            path: "Sources/StageManager"
        )
    ]
)