// swift-tools-version: 6.2
import PackageDescription

let mainActorDefault: [SwiftSetting] = [.defaultIsolation(MainActor.self)]

let package = Package(
    name: "MapoKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "MapoProtocol", targets: ["MapoProtocol"]),
        .library(name: "MapoClient", targets: ["MapoClient"]),
        .library(name: "MapoTerminal", targets: ["MapoTerminal"]),
        .library(name: "MapoEditor", targets: ["MapoEditor"]),
        .library(name: "MapoUI", targets: ["MapoUI"]),
        .library(name: "MapoAutomation", targets: ["MapoAutomation"]),
    ],
    dependencies: [
        // Terminal fallback engine (PLAN T0.8), MIT. Pinned below 1.12.0, whose Metal shader needs Xcode's
        // Metal Toolchain component; move to 1.20.0 once it is installed.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.11.2"),
        // Syntax highlighting (R-ED-2, ARCHITECTURE §4.4). SwiftTreeSitter is BSD-3, the grammars MIT. Some
        // grammars are pinned to their last release that lists `src/scanner.c` explicitly: later ones add it
        // with a `FileManager.fileExists` check relative to the working directory, which drops the scanner
        // when built as a dependency.
        .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter", exact: "0.25.0"),
        .package(
            url: "https://github.com/alex-pinkus/tree-sitter-swift",
            revision: "31d17fe7e818a2048c808b5c6fdc2dc792f4f5b5"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-rust", exact: "0.24.2"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-typescript", exact: "0.23.2"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-javascript", exact: "0.23.1"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-json", exact: "0.24.8"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-python", exact: "0.23.6"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-go", exact: "0.25.0"),
        .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-markdown", exact: "0.5.3"),
        .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-yaml", exact: "0.7.0"),
        .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-toml", exact: "0.7.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-bash", exact: "0.25.1"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-css", exact: "0.23.2"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-html", exact: "0.23.2"),
        .package(
            url: "https://github.com/DerekStride/tree-sitter-sql", revision: "39fdb006403747241244326e8af3b3e96b85381c"),
    ],
    targets: [
        // Generated Codable types stay in Swift 5 mode (ARCHITECTURE §4.1).
        .target(name: "MapoProtocol", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "MapoClient", dependencies: ["MapoProtocol"], swiftSettings: mainActorDefault),
        .target(
            name: "MapoTerminal", dependencies: ["MapoProtocol", .product(name: "SwiftTerm", package: "SwiftTerm")],
            swiftSettings: mainActorDefault),
        .target(
            name: "MapoEditor",
            dependencies: [
                "MapoProtocol",
                .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
                .product(name: "TreeSitterSwift", package: "tree-sitter-swift"),
                .product(name: "TreeSitterRust", package: "tree-sitter-rust"),
                .product(name: "TreeSitterTypeScript", package: "tree-sitter-typescript"),
                .product(name: "TreeSitterJavaScript", package: "tree-sitter-javascript"),
                .product(name: "TreeSitterJSON", package: "tree-sitter-json"),
                .product(name: "TreeSitterPython", package: "tree-sitter-python"),
                .product(name: "TreeSitterGo", package: "tree-sitter-go"),
                .product(name: "TreeSitterMarkdown", package: "tree-sitter-markdown"),
                .product(name: "TreeSitterYAML", package: "tree-sitter-yaml"),
                .product(name: "TreeSitterTOML", package: "tree-sitter-toml"),
                .product(name: "TreeSitterBash", package: "tree-sitter-bash"),
                .product(name: "TreeSitterCSS", package: "tree-sitter-css"),
                .product(name: "TreeSitterHTML", package: "tree-sitter-html"),
                .product(name: "TreeSitterSql", package: "tree-sitter-sql"),
            ],
            swiftSettings: mainActorDefault),
        .target(
            name: "MapoUI", dependencies: ["MapoProtocol", "MapoClient", "MapoTerminal", "MapoEditor"],
            swiftSettings: mainActorDefault),
        .target(
            name: "MapoAutomation", dependencies: ["MapoProtocol", "MapoClient", "MapoUI"],
            swiftSettings: mainActorDefault),
        .testTarget(name: "MapoProtocolTests", dependencies: ["MapoProtocol"]),
        .testTarget(name: "MapoTerminalTests", dependencies: ["MapoTerminal"]),
        .testTarget(name: "MapoAutomationTests", dependencies: ["MapoAutomation"]),
        .testTarget(name: "MapoEditorTests", dependencies: ["MapoEditor"]),
    ]
)
