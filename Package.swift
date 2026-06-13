// swift-tools-version:6.0

import PackageDescription

let package = Package(
    name: "SwiftCentrifuge",
    products: [
        .library(name: "SwiftCentrifuge", targets: ["SwiftCentrifuge"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf", from:"1.35.0")
    ],
    targets: [
        .target(
            name: "SwiftCentrifuge",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "SwiftCentrifugeTests",
            dependencies: [
                "SwiftCentrifuge",
                // Used by CompactionTests' in-process fake server to build/parse
                // length-delimited protobuf frames (BinaryDelimited).
                .product(name: "SwiftProtobuf", package: "swift-protobuf")
            ],
            resources: [
                .copy("testdata")
            ]
        )
    ]
)
