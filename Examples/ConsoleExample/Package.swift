// swift-tools-version:5.0

import PackageDescription

let package = Package(
    name: "ConsoleExample",
    platforms: [
        .macOS(.v10_14)
    ],
    dependencies: [
        .package(path: "../..")
    ],
    targets: [
        .target(
            name: "ConsoleExample",
            dependencies: ["SwiftCentrifuge"],
            path: ".",
            sources: ["main.swift"]
        )
    ]
)
