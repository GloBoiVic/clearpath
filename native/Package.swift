// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClearpathNative",
    platforms: [.macOS("15.0")],
    products: [
        .library(name: "ClearpathCore", targets: ["ClearpathCore"]),
        .executable(name: "clearpath-filter", targets: ["ClearpathFilter"]),
        .executable(name: "clearpath-service", targets: ["ClearpathServiceTool"])
    ],
    targets: [
        .target(name: "ClearpathCore"),
        .target(name: "ClearpathNetwork", dependencies: ["ClearpathCore"]),
        .executableTarget(name: "ClearpathFilter", dependencies: ["ClearpathCore", "ClearpathNetwork"]),
        .target(name: "ClearpathService", dependencies: ["ClearpathCore"]),
        .executableTarget(name: "ClearpathServiceTool", dependencies: ["ClearpathService"]),
        .testTarget(name: "ClearpathCoreTests", dependencies: ["ClearpathCore", "ClearpathNetwork"]),
        .testTarget(name: "ClearpathServiceTests", dependencies: ["ClearpathService"])
    ]
)
