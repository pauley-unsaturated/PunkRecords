// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PunkRecordsCore",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "PunkRecordsCore", targets: ["PunkRecordsCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-cmark.git", from: "0.6.0"),
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.4.0"),
    ],
    targets: [
        .target(
            name: "PunkRecordsCore",
            dependencies: [
                .product(name: "cmark-gfm", package: "swift-cmark"),
                .product(name: "Markdown", package: "swift-markdown"),
            ]
        ),
        .testTarget(
            name: "PunkRecordsCoreTests",
            dependencies: ["PunkRecordsCore"]
        ),
    ]
)
