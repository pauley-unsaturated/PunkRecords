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
        .package(path: "../PunkRecordsInfra"),
        .package(path: "../PunkRecordsTestSupport"),
        // Pulled in transitively via Infra, but named here so the session-path
        // harness (ScriptedLanguageModel / runMockSession) can import the
        // AnyLanguageModel `LanguageModel` protocol directly.
        .package(url: "https://github.com/huggingface/AnyLanguageModel", from: "0.8.0"),
    ],
    targets: [
        .target(
            name: "PunkRecordsEvals",
            dependencies: [
                "PunkRecordsCore",
                "PunkRecordsInfra",
                "PunkRecordsTestSupport",
                .product(name: "AnyLanguageModel", package: "AnyLanguageModel"),
            ]
        ),
    ]
)
