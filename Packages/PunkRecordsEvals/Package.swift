// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PunkRecordsEvals",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "PunkRecordsEvals", targets: ["PunkRecordsEvals"]),
    ],
    dependencies: [
        .package(path: "../PunkRecordsCore"),
        .package(path: "../PunkRecordsTestSupport"),
    ],
    targets: [
        .target(
            name: "PunkRecordsEvals",
            dependencies: [
                "PunkRecordsCore",
                "PunkRecordsTestSupport",
            ]
        ),
    ]
)
