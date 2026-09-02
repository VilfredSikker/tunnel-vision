// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Anchor",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Anchor",
            path: "Sources/Anchor"
        ),
        .testTarget(
            name: "AnchorTests",
            dependencies: ["Anchor"],
            path: "Tests/AnchorTests"
        ),
    ]
)
