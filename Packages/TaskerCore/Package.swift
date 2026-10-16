// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TaskerCore",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "TaskerCore", targets: ["TaskerCore"]),
    ],
    targets: [
        .target(
            name: "TaskerCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "TaskerCoreTests",
            dependencies: ["TaskerCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
