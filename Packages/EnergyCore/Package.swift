// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EnergyCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "EnergyCore", targets: ["EnergyCore"]),
    ],
    targets: [
        .target(name: "EnergyCore"),
        .testTarget(
            name: "EnergyCoreTests",
            dependencies: ["EnergyCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
