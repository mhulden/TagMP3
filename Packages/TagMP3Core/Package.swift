// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "TagMP3Core",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "TagMP3Model", targets: ["TagMP3Model"]),
        .library(name: "TagMP3Metadata", targets: ["TagMP3Metadata"]),
        .library(name: "TagMP3FileSystem", targets: ["TagMP3FileSystem"]),
        .library(name: "TagMP3Transformations", targets: ["TagMP3Transformations"]),
        .library(name: "TagMP3Providers", targets: ["TagMP3Providers"]),
        .library(name: "TagMP3MetadataSpike", targets: ["TagMP3MetadataSpike"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/jeonghi/TagLibSwift.git",
            revision: "530f2e1b78c0851a28fca16a279b649b17810029"
        )
    ],
    targets: [
        .target(
            name: "TagMP3Model"
        ),
        .target(
            name: "TagMP3Metadata",
            dependencies: [
                "TagMP3Model",
                .product(name: "TagLibSwift", package: "TagLibSwift")
            ],
            swiftSettings: [
                .interoperabilityMode(.Cxx)
            ]
        ),
        .target(
            name: "TagMP3FileSystem",
            dependencies: ["TagMP3Model"]
        ),
        .target(
            name: "TagMP3Transformations",
            dependencies: ["TagMP3Model"]
        ),
        .target(
            name: "TagMP3Providers",
            dependencies: ["TagMP3Model"]
        ),
        .target(
            name: "TagMP3MetadataSpike",
            dependencies: [
                .product(name: "TagLibSwift", package: "TagLibSwift")
            ],
            swiftSettings: [
                .interoperabilityMode(.Cxx)
            ]
        ),
        .testTarget(
            name: "TagMP3ModelTests",
            dependencies: ["TagMP3Model"]
        ),
        .testTarget(
            name: "TagMP3MetadataTests",
            dependencies: ["TagMP3Model", "TagMP3Metadata"],
            swiftSettings: [
                .interoperabilityMode(.Cxx)
            ]
        ),
        .testTarget(
            name: "TagMP3FileSystemTests",
            dependencies: ["TagMP3Model", "TagMP3FileSystem"]
        ),
        .testTarget(
            name: "TagMP3TransformationTests",
            dependencies: ["TagMP3Model", "TagMP3Transformations"]
        ),
        .testTarget(
            name: "TagMP3ProviderTests",
            dependencies: ["TagMP3Model", "TagMP3Providers"]
        ),
        .testTarget(
            name: "TagMP3MetadataSpikeTests",
            dependencies: ["TagMP3MetadataSpike", "TagLibSwift"],
            swiftSettings: [
                .interoperabilityMode(.Cxx)
            ]
        )
    ],
    cxxLanguageStandard: .cxx17
)
