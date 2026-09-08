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

/// Pushed events the guard cares about; everything else is `.other`.
enum HerdrEvent: Equatable, Sendable {
    case workspaceFocused(id: String)
    case workspaceRenamed(id: String, label: String?)
    case workspaceClosed(id: String)
    case workspaceCreated(HerdrWorkspace)
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
        default:
            return .other
        }
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

/// The slice of herdr's socket API the workspace lock needs.
@MainActor
protocol HerdrControlling: AnyObject {
    /// The server socket exists (herdr is installed and its server has run).
    var isAvailable: Bool { get }
    func snapshot() async throws -> HerdrSnapshot
    func focusWorkspace(id: String) async throws
    func notify(title: String, body: String?) async
    /// Long-lived subscription; ends when the connection drops.
    func events() -> AsyncStream<HerdrEvent>
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

    func events() -> AsyncStream<HerdrEvent> {
        let connection = HerdrLineConnection(path: socketPath)
        return AsyncStream { continuation in
            let task = Task { @MainActor in
                do {
                    try await connection.open()
                    let subscriptions: [[String: Any]] = [
                        ["type": "workspace.focused"],
                        ["type": "workspace.renamed"],
                        ["type": "workspace.closed"],
                        ["type": "workspace.created"],
                    ]
                    try await connection.send(HerdrProtocol.request(
                        id: "anchor-events",
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
        try await connection.send(HerdrProtocol.request(id: "anchor-\(method)", method: method, params: params))
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
