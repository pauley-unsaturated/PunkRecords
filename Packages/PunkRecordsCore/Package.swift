// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PunkRecordsCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "PunkRecordsCore", targets: ["PunkRecordsCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-cmark.git", from: "0.6.0"),
    ],
    targets: [
        .target(
            name: "PunkRecordsCore",
            dependencies: [
                .product(name: "cmark-gfm", package: "swift-cmark"),
            ]
        ),
        .testTarget(
            name: "PunkRecordsCoreTests",
            dependencies: ["PunkRecordsCore"]
        ),
    ]
)
