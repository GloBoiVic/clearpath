// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClearpathNative",
    platforms: [.macOS("15.0")],
    products: [
        .library(name: "ClearpathCore", targets: ["ClearpathCore"]),
        .executable(name: "ClearpathDNSProxy", targets: ["ClearpathDNSProxy"]),
        .executable(name: "clearpathctl", targets: ["ClearpathControl"])
    ],
    targets: [
        .target(name: "ClearpathCore"),
        .target(name: "ClearpathNetwork", dependencies: ["ClearpathCore"]),
        .executableTarget(name: "ClearpathDNSProxy", dependencies: ["ClearpathCore", "ClearpathNetwork"]),
        .executableTarget(name: "ClearpathControl", dependencies: ["ClearpathCore", "ClearpathNetwork"]),
        .testTarget(name: "ClearpathCoreTests", dependencies: ["ClearpathCore", "ClearpathNetwork"])
    ]
)
