import Foundation

/// One tool the MCP server offers.
public struct MCPTool {
    public let name: String
    public let description: String
    /// JSON Schema for the arguments.
    public let inputSchema: [String: Any]

    public init(name: String, description: String, inputSchema: [String: Any]) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

public struct MCPToolResult {
    public var text: String
    public var isError: Bool

    public init(text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }
}

/// The Model Context Protocol over stdio: newline-delimited JSON-RPC 2.0,
/// tools only. Pure: `handle(line:)` maps one request line to one response
/// line (nil for notifications), so the loop in main.swift stays trivial.
public struct MCPServer {
    public static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    public let name: String
    public let version: String
    public let tools: [MCPTool]
    public let call: (_ tool: String, _ arguments: [String: Any]) -> MCPToolResult

    public init(name: String, version: String, tools: [MCPTool], call: @escaping (String, [String: Any]) -> MCPToolResult) {
        self.name = name
        self.version = version
        self.tools = tools
        self.call = call
    }

    public func handle(line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        }
        let method = object["method"] as? String ?? ""
        let params = object["params"] as? [String: Any] ?? [:]
        guard let id = object["id"] else {
            // A notification (initialized, cancelled, progress): nothing to say.
            return nil
        }
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? ""
            let version = Self.supportedVersions.contains(requested) ? requested : Self.supportedVersions[0]
            return result(id, [
                "protocolVersion": version,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": name, "version": self.version],
            ])
        case "ping":
            return result(id, [:])
        case "tools/list":
            return result(id, ["tools": tools.map { tool in
                ["name": tool.name, "description": tool.description, "inputSchema": tool.inputSchema] as [String: Any]
            }])
        case "tools/call":
            guard let toolName = params["name"] as? String, tools.contains(where: { $0.name == toolName }) else {
                return error(id, code: -32602, message: "Unknown tool: \(params["name"] as? String ?? "")")
            }
            let outcome = call(toolName, params["arguments"] as? [String: Any] ?? [:])
            return result(id, [
                "content": [["type": "text", "text": outcome.text]],
                "isError": outcome.isError,
            ])
        default:
            return error(id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private func result(_ id: Any, _ result: [String: Any]) -> String {
        encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func error(_ id: Any, code: Int, message: String) -> String {
        encode(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private func encode(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error"}}"#
        }
        return text
    }
}
