// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SidekickDock",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "SidekickDock",
            path: "Sources/SidekickDock"
        ),
        .testTarget(
            name: "SidekickDockTests",
            dependencies: ["SidekickDock"],
            path: "Tests/SidekickDockTests"
        )
    ]
)
