// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Prism",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Prism", targets: ["Prism"]),
        .executable(name: "PrismApp", targets: ["PrismApp"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "Prism",
            path: "Sources/Prism"
        ),
        .executableTarget(
            name: "PrismApp",
            dependencies: ["Prism"],
            path: "Sources/PrismApp"
        ),
    ]
)
