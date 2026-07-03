// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PunkRecordsTestSupport",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "PunkRecordsTestSupport", targets: ["PunkRecordsTestSupport"]),
    ],
    dependencies: [
        .package(path: "../PunkRecordsCore"),
    ],
    targets: [
        .target(
            name: "PunkRecordsTestSupport",
            dependencies: ["PunkRecordsCore"]
        ),
    ]
)
