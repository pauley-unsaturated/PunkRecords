// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PunkRecordsInfra",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "PunkRecordsInfra", targets: ["PunkRecordsInfra"]),
    ],
    dependencies: [
        .package(path: "../PunkRecordsCore"),
        .package(path: "../PunkRecordsTestSupport"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/kishikawakatsumi/KeychainAccess.git", from: "4.2.2"),
        .package(url: "https://github.com/ChimeHQ/Neon.git", branch: "main"),
        .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter.git", branch: "main"),
        .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-markdown.git", from: "0.5.0"),
    ],
    targets: [
        .target(
            name: "PunkRecordsInfra",
            dependencies: [
                "PunkRecordsCore",
                .product(name: "GRDB", package: "GRDB.swift"),
                "KeychainAccess",
                .product(name: "Neon", package: "Neon"),
                .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
                .product(name: "TreeSitterMarkdown", package: "tree-sitter-markdown"),
            ]
        ),
        .testTarget(
            name: "PunkRecordsInfraTests",
            dependencies: [
                "PunkRecordsInfra",
                "PunkRecordsCore",
                "PunkRecordsTestSupport",
            ]
        ),
    ]
)
