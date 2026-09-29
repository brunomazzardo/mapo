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
    targets: [
        // Generated Codable types stay in Swift 5 mode (ARCHITECTURE §4.1).
        .target(name: "MapoProtocol", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "MapoClient", dependencies: ["MapoProtocol"], swiftSettings: mainActorDefault),
        .target(name: "MapoTerminal", dependencies: ["MapoProtocol"], swiftSettings: mainActorDefault),
        .target(name: "MapoEditor", dependencies: ["MapoProtocol"], swiftSettings: mainActorDefault),
        .target(
            name: "MapoUI", dependencies: ["MapoProtocol", "MapoClient", "MapoTerminal"],
            swiftSettings: mainActorDefault),
        .target(
            name: "MapoAutomation", dependencies: ["MapoProtocol", "MapoClient", "MapoUI"],
            swiftSettings: mainActorDefault),
        .testTarget(name: "MapoProtocolTests", dependencies: ["MapoProtocol"]),
    ]
)
