// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AgentSessionControl",
    platforms: [
        .iOS(.v17),
        .macOS(.v13)
    ],
    products: [
        .library(name: "AgentShared", targets: ["AgentShared"]),
        .library(name: "MacAgentCore", targets: ["MacAgentCore"]),
        .library(name: "iPhoneCore", targets: ["iPhoneCore"]),
        .executable(name: "MacAgentApp", targets: ["MacAgentApp"]),
        .executable(name: "iPhoneApp", targets: ["iPhoneApp"])
    ],
    targets: [
        .target(name: "AgentShared"),
        .target(
            name: "MacAgentCore",
            dependencies: ["AgentShared"]
        ),
        .target(
            name: "iPhoneCore",
            dependencies: ["AgentShared"]
        ),
        .executableTarget(
            name: "MacAgentApp",
            dependencies: ["AgentShared", "MacAgentCore"]
        ),
        .executableTarget(
            name: "iPhoneApp",
            dependencies: ["AgentShared", "iPhoneCore"]
        ),
        .testTarget(
            name: "MacAgentCoreTests",
            dependencies: ["AgentShared", "MacAgentCore"]
        ),
        .testTarget(
            name: "iPhoneCoreTests",
            dependencies: ["AgentShared", "MacAgentCore", "iPhoneCore"]
        )
    ]
)
