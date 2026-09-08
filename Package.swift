// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TunnelVision",
    platforms: [.macOS(.v14)],
    targets: [
        // Wire protocol, socket client, MCP plumbing and tool definitions
        // shared by the app and the MCP server.
        .target(
            name: "TunnelVisionControlKit",
            path: "Sources/TunnelVisionControlKit"
        ),
        .executableTarget(
            name: "TunnelVision",
            dependencies: ["TunnelVisionControlKit"],
            path: "Sources/TunnelVision"
        ),
        // Stdio MCP server that forwards tool calls to the running app.
        .executableTarget(
            name: "tunnelvision-mcp",
            dependencies: ["TunnelVisionControlKit"],
            path: "Sources/TunnelVisionMCP"
        ),
        .testTarget(
            name: "TunnelVisionTests",
            dependencies: ["TunnelVision", "TunnelVisionControlKit"],
            path: "Tests/TunnelVisionTests"
        ),
    ]
)
