// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ManageArms",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "ManageArmsCore"),
        .executableTarget(name: "ManageArms", dependencies: ["ManageArmsCore"]),
        .testTarget(name: "ManageArmsCoreTests", dependencies: ["ManageArmsCore"]),
    ]
)
