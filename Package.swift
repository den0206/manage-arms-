// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AgentTool",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "AgentToolCore"),
        .executableTarget(name: "AgentToolCoreCLI", dependencies: ["AgentToolCore"]),
        .testTarget(name: "AgentToolCoreTests", dependencies: ["AgentToolCore"]),
    ]
)
