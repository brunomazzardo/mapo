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
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.11.2")
    ],
    targets: [
        // Generated Codable types stay in Swift 5 mode (ARCHITECTURE §4.1).
        .target(name: "MapoProtocol", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "MapoClient", dependencies: ["MapoProtocol"], swiftSettings: mainActorDefault),
        .target(
            name: "MapoTerminal", dependencies: ["MapoProtocol", .product(name: "SwiftTerm", package: "SwiftTerm")],
            swiftSettings: mainActorDefault),
        .target(name: "MapoEditor", dependencies: ["MapoProtocol"], swiftSettings: mainActorDefault),
        .target(
            name: "MapoUI", dependencies: ["MapoProtocol", "MapoClient", "MapoTerminal"],
            swiftSettings: mainActorDefault),
        .target(
            name: "MapoAutomation", dependencies: ["MapoProtocol", "MapoClient", "MapoUI"],
            swiftSettings: mainActorDefault),
        .testTarget(name: "MapoProtocolTests", dependencies: ["MapoProtocol"]),
        .testTarget(name: "MapoTerminalTests", dependencies: ["MapoTerminal"]),
        .testTarget(name: "MapoAutomationTests", dependencies: ["MapoAutomation"]),
    ]
)
