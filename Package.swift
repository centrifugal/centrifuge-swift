// swift-tools-version:5.1

import PackageDescription

let package = Package(
    name: "SwiftCentrifuge",
    dependencies: [
        .package(url: "https://github.com/daltoniam/Starscream", from:"3.0.6"),
        .package(url: "https://github.com/apple/swift-protobuf", from:"1.7.0")
    ],
    targets: [
        .target(
            name: "SwiftCentrifuge",
            dependencies: ["Starscream", "SwiftProtobuf"]
        ),
        .testTarget(
            name: "SwiftCentrifugeTests",
            dependencies: ["SwiftCentrifuge"]
        )
    ]
)
