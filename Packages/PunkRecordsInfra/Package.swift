// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PunkRecordsInfra",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "PunkRecordsInfra", targets: ["PunkRecordsInfra"]),
    ],
    dependencies: [
        .package(path: "../PunkRecordsCore"),
        .package(path: "../PunkRecordsTestSupport"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/kishikawakatsumi/KeychainAccess.git", from: "4.2.2"),
        // API-compatible drop-in for Apple's FoundationModels with pluggable
        // backends (Ollama, MLX, llama.cpp, remote providers). Backs the local
        // "Ollama" provider; works back to macOS 14, so not gated on macOS 26+.
        .package(url: "https://github.com/huggingface/AnyLanguageModel", from: "0.8.0"),
        .package(url: "https://github.com/ChimeHQ/Neon.git", branch: "main"),
        .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter.git", branch: "main"),
        .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-markdown.git", from: "0.5.0"),
        // The Swift grammar generates parser.c at build time; this tag ships
        // the pre-generated sources so SPM can compile it directly.
        .package(url: "https://github.com/alex-pinkus/tree-sitter-swift.git", revision: "0.7.2-with-generated-files"),
        // Pin to tagged releases — their Package.swift lists src/scanner.c
        // explicitly, whereas the master branches use a CWD-relative
        // fileExists check that drops the external scanner under SPM (causing
        // undefined `*_external_scanner_*` symbols at link time).
        .package(url: "https://github.com/tree-sitter/tree-sitter-python.git", exact: "0.23.6"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-javascript.git", exact: "0.23.1"),
        // Same tagged-release rule as above: each lists src/scanner.c (where it
        // has one) and depends on ChimeHQ/SwiftTreeSitter, so no duplicate
        // SwiftTreeSitter product enters the graph. TypeScript ships both the
        // TypeScript and TSX grammars from one package.
        .package(url: "https://github.com/tree-sitter/tree-sitter-rust.git", exact: "0.24.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-c.git", exact: "0.23.6"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-cpp.git", exact: "0.23.4"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-typescript.git", exact: "0.23.2"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-bash.git", exact: "0.23.3"),
        // 0.24.3 is the last json tag that ships a Package.swift — SPM support
        // was dropped in 0.24.4+. Its highlight query is self-contained.
        .package(url: "https://github.com/tree-sitter/tree-sitter-json.git", exact: "0.24.3"),
    ],
    targets: [
        .target(
            name: "PunkRecordsInfra",
            dependencies: [
                "PunkRecordsCore",
                .product(name: "GRDB", package: "GRDB.swift"),
                "KeychainAccess",
                .product(name: "AnyLanguageModel", package: "AnyLanguageModel"),
                .product(name: "Neon", package: "Neon"),
                .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
                .product(name: "TreeSitterMarkdown", package: "tree-sitter-markdown"),
                .product(name: "TreeSitterSwift", package: "tree-sitter-swift"),
                .product(name: "TreeSitterPython", package: "tree-sitter-python"),
                .product(name: "TreeSitterJavaScript", package: "tree-sitter-javascript"),
                .product(name: "TreeSitterRust", package: "tree-sitter-rust"),
                .product(name: "TreeSitterC", package: "tree-sitter-c"),
                .product(name: "TreeSitterCPP", package: "tree-sitter-cpp"),
                .product(name: "TreeSitterTypeScript", package: "tree-sitter-typescript"),
                .product(name: "TreeSitterBash", package: "tree-sitter-bash"),
                .product(name: "TreeSitterJSON", package: "tree-sitter-json"),
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
