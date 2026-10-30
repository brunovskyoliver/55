// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AgentSessionControl",
    platforms: [
        .iOS(.v26),
        .macOS(.v26)
    ],
    products: [
        .library(name: "AgentShared", targets: ["AgentShared"]),
        .library(name: "MacAgentCore", targets: ["MacAgentCore"]),
        .library(name: "iPhoneCore", targets: ["iPhoneCore"]),
        .library(name: "iPhoneApp", targets: ["iPhoneApp"]),
        .executable(name: "MacAgentApp", targets: ["MacAgentApp"]),
        .executable(name: "agent-debug", targets: ["AgentDebugCLI"])
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
            name: "AgentDebugCLI",
            dependencies: ["AgentShared", "MacAgentCore"]
        ),
        .target(
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
