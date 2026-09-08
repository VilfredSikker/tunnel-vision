import Darwin
import Foundation

/// One request, one response, blocking. Meant for the MCP server, which
/// handles one tool call at a time.
public struct ControlClient: Sendable {
    public let socketPath: String
    /// How long to wait for the app's answer.
    public var timeoutSeconds: Int = 10

    public init(socketPath: String = ControlProtocol.defaultSocketPath) {
        self.socketPath = socketPath
    }

    /// The socket file exists: Tunnel Vision has run since login.
    public var isAvailable: Bool {
        FileManager.default.fileExists(atPath: socketPath)
    }

    public func call(method: String, params: [String: Any] = [:]) throws -> [String: Any] {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlError.unavailable("could not create a socket") }
        defer { close(fd) }

        var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = try UnixSocketAddress.make(path: socketPath)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, UnixSocketAddress.length) }
        }
        guard connected == 0 else {
            throw ControlError.unavailable("Tunnel Vision is not running (no listener at \(socketPath))")
        }

        let request = ControlProtocol.request(id: UUID().uuidString, method: method, params: params)
        try request.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var sent = 0
            while sent < bytes.count {
                let n = write(fd, base + sent, bytes.count - sent)
                guard n > 0 else { throw ControlError.unavailable("write failed") }
                sent += n
            }
        }

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while !buffer.contains(0x0A) {
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { throw ControlError.unavailable("Tunnel Vision closed the connection without answering") }
            buffer.append(chunk, count: n)
        }
        guard let newline = buffer.firstIndex(of: 0x0A) else {
            throw ControlError.malformed
        }
        return try ControlProtocol.parseResponse(buffer.subdata(in: buffer.startIndex..<newline))
    }
}
