import TunnelVisionControlKit
import Foundation

// tunnelvision-mcp: an MCP server over stdio that forwards tool calls to the
// running Tunnel Vision app through its control socket. Register it with
//   claude mcp add tunnelvision -- /path/to/tunnelvision-mcp
// If Tunnel Vision is not running, the first call launches it and waits for the
// socket before answering.

let client = ControlClient()
let bundleID = "com.tunnelvision.timer"

func log(_ text: String) {
    FileHandle.standardError.write(Data(("tunnelvision-mcp: " + text + "\n").utf8))
}

/// Launches Tunnel Vision in the background and waits for its socket, up to ~6 s.
@MainActor
func launchTunnelVision() -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-g", "-b", bundleID]
    do {
        try process.run()
    } catch {
        log("could not launch Tunnel Vision: \(error)")
        return false
    }
    process.waitUntilExit()
    for _ in 0..<30 {
        Thread.sleep(forTimeInterval: 0.2)
        if client.isAvailable, (try? client.call(method: "state.get")) != nil {
            return true
        }
    }
    return false
}

@MainActor
func callTunnelVision(method: String, params: [String: Any]) throws -> [String: Any] {
    do {
        return try client.call(method: method, params: params)
    } catch ControlError.unavailable {
        log("Tunnel Vision is not running; launching it")
        guard launchTunnelVision() else {
            throw ControlError.unavailable("Tunnel Vision is not running and could not be launched. Open Tunnel Vision.app and try again.")
        }
        return try client.call(method: method, params: params)
    }
}

func pretty(_ object: [String: Any]) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
          let text = String(data: data, encoding: .utf8) else { return "{}" }
    return text
}

let server = MCPServer(name: "tunnelvision", version: "0.2.0", tools: ControlTools.all) { tool, arguments in
    guard let route = ControlTools.route(tool: tool, arguments: arguments) else {
        let known = ControlTools.all.contains { $0.name == tool }
        return MCPToolResult(text: known ? "Missing or invalid arguments for \(tool)" : "Unknown tool \(tool)", isError: true)
    }
    do {
        return MCPToolResult(text: pretty(try callTunnelVision(method: route.method, params: route.params)))
    } catch let error as ControlError {
        return MCPToolResult(text: error.message, isError: true)
    } catch {
        return MCPToolResult(text: String(describing: error), isError: true)
    }
}

let output = FileHandle.standardOutput
while let line = readLine(strippingNewline: true) {
    guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
    if let response = server.handle(line: line) {
        output.write(Data((response + "\n").utf8))
    }
}
