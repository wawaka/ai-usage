// swift-tools-version: 5.10
import PackageDescription

var products: [Product] = [.executable(name: "ai-usage-cli", targets: ["ai-usage-cli"])]
var targets: [Target] = [
    // Foundation-only: providers, credential discovery, OAuth, burn analysis, storage.
    // Builds on Linux too, so it can be tested without a Mac.
    .target(name: "AIUsageCore"),
    // Diagnostic CLI sharing the same core.
    .executableTarget(name: "ai-usage-cli", dependencies: ["AIUsageCore"], path: "Sources/AIUsageCLI"),
    .testTarget(name: "AIUsageCoreTests", dependencies: ["AIUsageCore"]),
]

#if os(macOS)
// The menu bar app (AppKit + SwiftUI).
products.append(.executable(name: "AIUsage", targets: ["AIUsage"]))
targets.append(.executableTarget(name: "AIUsage", dependencies: ["AIUsageCore"]))
#endif

let package = Package(
    name: "ai-usage",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
