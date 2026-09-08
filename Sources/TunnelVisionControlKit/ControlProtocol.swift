import Darwin
import Foundation

/// Tunnel Vision's control API speaks newline-delimited JSON over a Unix socket in
/// Application Support: one request per line, one response line back.
///
///     {"id": 1, "method": "tasks.add", "params": {"title": "Write docs"}}
///     {"id": 1, "result": {"task": {...}}}
///     {"id": 1, "error": {"code": -32602, "message": "title is required"}}
public enum ControlProtocol {
    public static let socketFileName = "control.sock"

    /// `~/Library/Application Support/TunnelVision/control.sock`.
    public static var defaultSocketPath: String {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("TunnelVision", isDirectory: true)
            .appendingPathComponent(socketFileName).path
    }

    public struct Request {
        public let id: Any
        public let method: String
        public let params: [String: Any]
    }

    public static func request(id: Any, method: String, params: [String: Any]) -> Data {
        line(["id": id, "method": method, "params": params])
    }

    public static func parseRequest(_ line: Data) -> Request? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let method = object["method"] as? String else { return nil }
        return Request(
            id: object["id"] ?? NSNull(),
            method: method,
            params: object["params"] as? [String: Any] ?? [:]
        )
    }

    public static func response(id: Any, result: [String: Any]) -> Data {
        line(["id": id, "result": result])
    }

    public static func errorResponse(id: Any?, error: ControlError) -> Data {
        line(["id": id ?? NSNull(), "error": ["code": error.code, "message": error.message]])
    }

    /// The result of a response line; a wire error becomes `ControlError.server`.
    public static func parseResponse(_ line: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            throw ControlError.malformed
        }
        if let error = object["error"] as? [String: Any] {
            throw ControlError.server(
                code: error["code"] as? Int ?? -32000,
                message: error["message"] as? String ?? "unknown error"
            )
        }
        return object["result"] as? [String: Any] ?? [:]
    }

    private static func line(_ object: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        data.append(0x0A)
        return data
    }
}

public enum ControlError: Error, Equatable {
    /// The socket is not there or refused: Tunnel Vision is not running.
    case unavailable(String)
    case malformed
    case unknownMethod(String)
    case invalidParams(String)
    case notFound(String)
    case refused(String)
    /// An error the server sent back.
    case server(code: Int, message: String)

    public var code: Int {
        switch self {
        case .unavailable: -32003
        case .malformed: -32700
        case .unknownMethod: -32601
        case .invalidParams: -32602
        case .notFound: -32001
        case .refused: -32000
        case .server(let code, _): code
        }
    }

    public var message: String {
        switch self {
        case .unavailable(let text): text
        case .malformed: "malformed message"
        case .unknownMethod(let method): "unknown method \(method)"
        case .invalidParams(let text), .notFound(let text), .refused(let text): text
        case .server(_, let message): message
        }
    }
}

/// `sockaddr_un` for a path, shared by the listener and the client.
public enum UnixSocketAddress {
    public static func make(path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else {
            throw ControlError.refused("socket path too long: \(path)")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.enumerated() {
                buffer[index] = byte
            }
            buffer[bytes.count] = 0
        }
        return address
    }

    public static var length: socklen_t {
        socklen_t(MemoryLayout<sockaddr_un>.size)
    }
}
