// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ManageArms",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "ManageArmsCore"),
        .executableTarget(name: "ManageArms", dependencies: ["ManageArmsCore"]),
        .testTarget(name: "ManageArmsCoreTests", dependencies: ["ManageArmsCore"]),
    ]
)
