// swift-tools-version: 6.2
import PackageDescription

var products: [Product] = [.executable(name: "ai-usage-cli", targets: ["ai-usage-cli"])]
var targets: [Target] = [
    // Foundation-only: providers, credential discovery, OAuth, polling, storage.
    // Builds on Linux too, so it can be tested without a Mac.
    .target(name: "AIUsageCore"),
    // Diagnostic CLI sharing the same core.
    .executableTarget(name: "ai-usage-cli", dependencies: ["AIUsageCore"], path: "Sources/AIUsageCLI"),
    .testTarget(name: "AIUsageCoreTests", dependencies: ["AIUsageCore"]),
]

#if os(macOS)
// The menu bar app (AppKit + SwiftUI). Swift 5 language mode: its AppKit callbacks and Combine
// sinks aren't audited for Swift 6 strict concurrency yet.
products.append(.executable(name: "AIUsage", targets: ["AIUsage"]))
targets.append(.executableTarget(name: "AIUsage", dependencies: ["AIUsageCore"],
                                 swiftSettings: [.swiftLanguageMode(.v5)]))
#endif

let package = Package(
    name: "ai-usage",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
