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
    ],
    targets: [
        .target(
            name: "PunkRecordsInfra",
            dependencies: [
                "PunkRecordsCore",
                .product(name: "GRDB", package: "GRDB.swift"),
                "KeychainAccess",
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
