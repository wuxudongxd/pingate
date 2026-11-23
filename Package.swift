// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PinGate",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "PinGateCore",
            targets: ["PinGateCore"]
        ),
        .executable(
            name: "PinGateApp",
            targets: ["PinGateApp"]
        ),
        .executable(
            name: "pingate-cli",
            targets: ["pingate-cli"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.3")
    ],
    targets: [
        .target(
            name: "PinGateCore",
            dependencies: [
                .product(name: "Yams", package: "Yams")
            ],
            path: "Sources/PinGateCore"
        ),
        .executableTarget(
            name: "PinGateApp",
            dependencies: ["PinGateCore"],
            path: "Sources/PinGateApp"
        ),
        .executableTarget(
            name: "pingate-cli",
            dependencies: ["PinGateCore"],
            path: "Sources/PinGateCLI"
        ),
        .testTarget(
            name: "PinGateCoreTests",
            dependencies: ["PinGateCore"],
            path: "Tests/PinGateCoreTests"
        )
    ]
)
