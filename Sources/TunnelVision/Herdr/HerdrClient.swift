import Foundation
import Network
import os

// MARK: - Model

/// One herdr workspace (a repo or worktree checkout with its tabs and panes).
struct HerdrWorkspace: Identifiable, Hashable, Sendable {
    /// Opaque public id such as `w1`; stable for the life of the session file.
    let id: String
    /// Repo or worktree name, or the user's custom name.
    let label: String
    let repoName: String?
    let checkoutPath: String?
    let focused: Bool
}

struct HerdrSnapshot: Equatable, Sendable {
    let focusedWorkspaceID: String?
    let workspaces: [HerdrWorkspace]
}

/// What herdr reads an agent pane as doing.
enum HerdrAgentStatus: String, Sendable {
    case idle
    case working
    /// Showing a prompt: a permission, a question or a plan approval.
    case blocked
    case done
    case unknown

    /// Ready for a new prompt.
    var isIdle: Bool { self == .idle || self == .done }
}

/// One agent pane, as `agent.list` reports it.
struct HerdrAgent: Identifiable, Equatable, Sendable {
    let paneID: String
    let workspaceID: String
    let cwd: String?
    /// The agent kind, such as `claude`.
    let agent: String?
    let status: HerdrAgentStatus
    let focused: Bool
    /// The Claude session id, when herdr knows it.
    let sessionID: String?

    var id: String { paneID }
}

/// Pushed events the guard and the background agents care about;
/// everything else is `.other`.
enum HerdrEvent: Equatable, Sendable {
    case workspaceFocused(id: String)
    case workspaceRenamed(id: String, label: String?)
    case workspaceClosed(id: String)
    case workspaceCreated(HerdrWorkspace)
    /// Nil status: herdr no longer reads an agent in the pane.
    case agentStatusChanged(paneID: String, status: HerdrAgentStatus?)
    case other
}

enum HerdrError: Error, Equatable {
    case unavailable
    case disconnected
    case server(String)
    case malformed
}

// MARK: - Wire format (pure, testable)

/// herdr speaks newline-delimited JSON over a Unix socket: one request per
/// line, one response line per request, then pushed event lines on a
/// subscription connection.
enum HerdrProtocol {
    /// What the workspace lock follows.
    static let workspaceEventKinds = ["workspace.focused", "workspace.renamed", "workspace.closed", "workspace.created"]
    /// What background tasks follow. Its own subscription, so a kind herdr
    /// refuses cannot take the workspace lock down with it.
    static let agentEventKinds = ["pane.agent_status_changed"]

    static func request(id: String, method: String, params: [String: Any]) -> Data {
        let body: [String: Any] = ["id": id, "method": method, "params": params]
        var data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        data.append(0x0A)
        return data
    }

    static func errorMessage(in line: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let error = object["error"] as? [String: Any] else { return nil }
        // JSON-RPC errors carry a numeric code; herdr may also send a string.
        if let message = error["message"] as? String, !message.isEmpty {
            return message
        }
        if let code = error["code"] as? Int {
            return "\(code)"
        }
        if let code = error["code"] as? String {
            return code
        }
        return "unknown error"
    }

    static func parseSnapshot(_ line: Data) throws -> HerdrSnapshot {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let result = object["result"] as? [String: Any] else { throw HerdrError.malformed }
        // `session.snapshot` nests under "snapshot"; `workspace.list` does not.
        let body = (result["snapshot"] as? [String: Any]) ?? result
        guard let rawWorkspaces = body["workspaces"] as? [[String: Any]] else { throw HerdrError.malformed }
        return HerdrSnapshot(
            focusedWorkspaceID: body["focused_workspace_id"] as? String,
            workspaces: rawWorkspaces.compactMap(workspace(from:))
        )
    }

    static func parseEvent(_ line: Data) -> HerdrEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
        guard let data = object["data"] as? [String: Any] else { return nil }
        let kind = (data["type"] as? String) ?? (object["event"] as? String) ?? ""
        switch kind.replacingOccurrences(of: ".", with: "_") {
        case "workspace_focused":
            guard let id = data["workspace_id"] as? String else { return nil }
            return .workspaceFocused(id: id)
        case "workspace_renamed":
            guard let id = data["workspace_id"] as? String else { return nil }
            return .workspaceRenamed(id: id, label: data["label"] as? String)
        case "workspace_closed":
            guard let id = data["workspace_id"] as? String else { return nil }
            return .workspaceClosed(id: id)
        case "workspace_created":
            guard let raw = data["workspace"] as? [String: Any], let workspace = workspace(from: raw) else { return nil }
            return .workspaceCreated(workspace)
        case "pane_agent_status_changed":
            guard let pane = data["pane_id"] as? String else { return nil }
            let status = (data["agent_status"] as? String).map { HerdrAgentStatus(rawValue: $0) ?? .unknown }
            return .agentStatusChanged(paneID: pane, status: status)
        default:
            return .other
        }
    }

    /// `agent.list`: `{"result":{"type":"agent_list","agents":[…]}}`.
    static func parseAgents(_ line: Data) throws -> [HerdrAgent] {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let result = object["result"] as? [String: Any],
              let raw = result["agents"] as? [[String: Any]] else { throw HerdrError.malformed }
        return raw.compactMap(agent(from:))
    }

    static func agent(from raw: [String: Any]) -> HerdrAgent? {
        guard let pane = raw["pane_id"] as? String, let workspace = raw["workspace_id"] as? String else { return nil }
        // A session reference of kind "path" is a transcript path, not an id.
        let session = raw["agent_session"] as? [String: Any]
        let sessionID = (session?["kind"] as? String ?? "id") == "id" ? session?["value"] as? String : nil
        return HerdrAgent(
            paneID: pane,
            workspaceID: workspace,
            cwd: raw["cwd"] as? String,
            agent: raw["agent"] as? String,
            status: (raw["agent_status"] as? String).flatMap(HerdrAgentStatus.init(rawValue:)) ?? .unknown,
            focused: (raw["focused"] as? Bool) ?? false,
            sessionID: sessionID
        )
    }

    /// `agent.read`: `{"result":{"type":"pane_read","read":{"text":…}}}`, per
    /// herdr's bundled API schema (protocol 22). A bare `text` is accepted too.
    static func parseRead(_ line: Data) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let result = object["result"] as? [String: Any] else { throw HerdrError.malformed }
        if let read = result["read"] as? [String: Any], let text = read["text"] as? String {
            return text
        }
        if let text = result["text"] as? String {
            return text
        }
        throw HerdrError.malformed
    }

    static func workspace(from raw: [String: Any]) -> HerdrWorkspace? {
        guard let id = raw["workspace_id"] as? String else { return nil }
        let worktree = raw["worktree"] as? [String: Any]
        return HerdrWorkspace(
            id: id,
            label: (raw["label"] as? String) ?? id,
            repoName: worktree?["repo_name"] as? String,
            checkoutPath: worktree?["checkout_path"] as? String,
            focused: (raw["focused"] as? Bool) ?? false
        )
    }
}

// MARK: - Client

/// The slice of herdr's socket API the workspace lock and the background
/// agents need.
@MainActor
protocol HerdrControlling: AnyObject {
    /// The server socket exists (herdr is installed and its server has run).
    var isAvailable: Bool { get }
    func snapshot() async throws -> HerdrSnapshot
    func focusWorkspace(id: String) async throws
    func notify(title: String, body: String?) async
    /// Every agent pane herdr knows.
    func agents() async throws -> [HerdrAgent]
    /// Submits `text` to the agent in the pane as a prompt.
    func prompt(target paneID: String, text: String) async throws
    /// The pane's visible screen as plain text.
    func read(target paneID: String) async throws -> String
    /// Key presses by herdr name, such as `Down` or `Enter`.
    func sendKeys(target paneID: String, keys: [String]) async throws
    /// Brings the agent's pane forward inside herdr, switching to its
    /// workspace.
    func focusAgent(target paneID: String) async throws
    /// Long-lived subscription to the given event kinds; ends when the
    /// connection drops.
    func events(kinds: [String]) -> AsyncStream<HerdrEvent>
}

@MainActor
final class HerdrSocketClient: HerdrControlling {
    private static let log = Logger(subsystem: "com.tunnelvision.timer", category: "herdr")

    let socketPath: String

    /// Default: the default-session socket under the herdr config directory.
    init(socketPath: String? = nil) {
        if let socketPath {
            self.socketPath = socketPath
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            self.socketPath = home.appendingPathComponent(".config/herdr/herdr.sock").path
        }
    }

    var isAvailable: Bool {
        FileManager.default.fileExists(atPath: socketPath)
    }

    func snapshot() async throws -> HerdrSnapshot {
        let line = try await call(method: "session.snapshot", params: [:])
        return try HerdrProtocol.parseSnapshot(line)
    }

    func focusWorkspace(id: String) async throws {
        _ = try await call(method: "workspace.focus", params: ["workspace_id": id])
    }

    func notify(title: String, body: String?) async {
        var params: [String: Any] = ["title": title, "sound": "none"]
        if let body { params["body"] = body }
        _ = try? await call(method: "notification.show", params: params)
    }

    func agents() async throws -> [HerdrAgent] {
        let line = try await call(method: "agent.list", params: [:])
        return try HerdrProtocol.parseAgents(line)
    }

    func prompt(target paneID: String, text: String) async throws {
        _ = try await call(method: "agent.prompt", params: ["target": paneID, "text": text])
    }

    func read(target paneID: String) async throws -> String {
        let line = try await call(method: "agent.read", params: ["target": paneID, "source": "visible", "strip_ansi": true])
        return try HerdrProtocol.parseRead(line)
    }

    func sendKeys(target paneID: String, keys: [String]) async throws {
        _ = try await call(method: "agent.send_keys", params: ["target": paneID, "keys": keys])
    }

    func focusAgent(target paneID: String) async throws {
        _ = try await call(method: "agent.focus", params: ["target": paneID])
    }

    func events(kinds: [String]) -> AsyncStream<HerdrEvent> {
        let connection = HerdrLineConnection(path: socketPath)
        return AsyncStream { continuation in
            let task = Task { @MainActor in
                do {
                    try await connection.open()
                    let subscriptions: [[String: Any]] = kinds.map { ["type": $0] }
                    try await connection.send(HerdrProtocol.request(
                        id: "tunnelvision-events",
                        method: "events.subscribe",
                        params: ["subscriptions": subscriptions]
                    ))
                    let ack = try await connection.nextLine()
                    if let message = HerdrProtocol.errorMessage(in: ack) {
                        throw HerdrError.server(message)
                    }
                    while !Task.isCancelled {
                        let line = try await connection.nextLine()
                        if let event = HerdrProtocol.parseEvent(line) {
                            continuation.yield(event)
                        }
                    }
                } catch {
                    Self.log.info("event stream ended: \(String(describing: error), privacy: .public)")
                }
                connection.close()
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
                Task { @MainActor in connection.close() }
            }
        }
    }

    /// One request, one response line, connection closed.
    private func call(method: String, params: [String: Any]) async throws -> Data {
        guard isAvailable else { throw HerdrError.unavailable }
        let connection = HerdrLineConnection(path: socketPath)
        defer { connection.close() }
        try await connection.open()
        try await connection.send(HerdrProtocol.request(id: "tunnelvision-\(method)", method: method, params: params))
        let line = try await connection.nextLine()
        if let message = HerdrProtocol.errorMessage(in: line) {
            throw HerdrError.server(message)
        }
        return line
    }
}

/// One Unix-socket connection with line framing. All Network callbacks are
/// delivered on the main queue, which is what makes the main-actor state safe.
@MainActor
final class HerdrLineConnection {
    private let connection: NWConnection
    private var buffer = Data()
    private var closed = false
    private var pendingReady: CheckedContinuation<Void, Error>?
    private var pendingLine: CheckedContinuation<Data, Error>?

    init(path: String) {
        connection = NWConnection(to: .unix(path: path), using: .tcp)
    }

    func open() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pendingReady = continuation
            connection.stateUpdateHandler = { state in
                MainActor.assumeIsolated {
                    self.handle(state: state)
                }
            }
            connection.start(queue: .main)
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func nextLine() async throws -> Data {
        if let line = takeLine() { return line }
        guard !closed else { throw HerdrError.disconnected }
        return try await withCheckedThrowingContinuation { continuation in
            pendingLine = continuation
            receiveMore()
        }
    }

    func close() {
        closed = true
        connection.cancel()
        failPending(HerdrError.disconnected)
    }

    // MARK: Internals

    private func handle(state: NWConnection.State) {
        switch state {
        case .ready:
            pendingReady?.resume()
            pendingReady = nil
        case .failed(let error):
            closed = true
            failPending(error)
        case .waiting(let error):
            // A missing socket file surfaces here rather than as .failed.
            closed = true
            connection.cancel()
            failPending(error)
        case .cancelled:
            closed = true
            failPending(HerdrError.disconnected)
        default:
            break
        }
    }

    private func receiveMore() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            MainActor.assumeIsolated {
                self.handleChunk(data, isComplete: isComplete, error: error)
            }
        }
    }

    private func handleChunk(_ data: Data?, isComplete: Bool, error: NWError?) {
        if let data {
            buffer.append(data)
        }
        if let error {
            closed = true
            failPending(error)
            return
        }
        if let line = takeLine() {
            pendingLine?.resume(returning: line)
            pendingLine = nil
            return
        }
        if isComplete {
            closed = true
            failPending(HerdrError.disconnected)
            return
        }
        if pendingLine != nil {
            receiveMore()
        }
    }

    private func takeLine() -> Data? {
        guard let newline = buffer.firstIndex(of: 0x0A) else { return nil }
        let line = buffer.subdata(in: buffer.startIndex..<newline)
        buffer.removeSubrange(buffer.startIndex...newline)
        return line
    }

    private func failPending(_ error: Error) {
        pendingReady?.resume(throwing: error)
        pendingReady = nil
        pendingLine?.resume(throwing: error)
        pendingLine = nil
    }
}
