// swift-tools-version:4.0

import PackageDescription

let package = Package(
    name: "SwiftCentrifuge",
    dependencies: [
        .package(url: "https://github.com/daltoniam/Starscream.git", from:"3.0.6"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from:"1.3.1")
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
