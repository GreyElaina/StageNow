// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "StageNow",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "StageNow", targets: ["StageNow"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "StageNow",
            dependencies: [],
            path: "Sources/StageNow"
        )
    ]
)