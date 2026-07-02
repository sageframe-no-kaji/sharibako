// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Sharibako",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "SharibakoCore",
            targets: ["SharibakoCore"]
        ),
        .executable(
            name: "sharibako",
            targets: ["SharibakoCLI"]
        ),
        .executable(
            name: "Sharibako",
            targets: ["Sharibako"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-log", from: "1.6.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
    ],
    targets: [
        .target(
            name: "SharibakoCore",
            dependencies: [
                "Yams",
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .executableTarget(
            name: "SharibakoCLI",
            dependencies: [
                "SharibakoCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .executableTarget(
            name: "Sharibako",
            dependencies: ["SharibakoCore"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "SharibakoCoreTests",
            dependencies: ["SharibakoCore"]
        ),
        .testTarget(
            name: "SharibakoCLITests",
            dependencies: [
                "SharibakoCore",
                "SharibakoCLI",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
