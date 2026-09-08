import TunnelVisionControlKit
import Darwin
import Foundation
import os

/// Listens on the control socket and answers each request line through the
/// handler. Everything runs on the main queue, so the handler can touch the
/// model directly.
@MainActor
final class ControlServer {
    typealias Handler = @MainActor (_ method: String, _ params: [String: Any]) throws -> [String: Any]

    private static let log = Logger(subsystem: "com.tunnelvision.timer", category: "control")

    private struct Client {
        var buffer = Data()
        var source: DispatchSourceRead
    }

    let path: String
    private let handler: Handler
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clients: [Int32: Client] = [:]

    init(path: String = ControlProtocol.defaultSocketPath, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    var isListening: Bool { listenFD >= 0 }

    func start() throws {
        guard listenFD < 0 else { return }
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // The directory is created under the process umask (usually 0755);
        // tighten it so no other local user can reach into the socket.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlError.refused("socket() failed: \(errno)") }
        var address = try UnixSocketAddress.make(path: path)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, UnixSocketAddress.length) }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            let code = errno
            close(fd)
            throw ControlError.refused("bind/listen failed: \(code)")
        }
        // Socket files ignore the creating process's umask in some macOS
        // versions; fchmod pins the mode on the open descriptor regardless.
        fchmod(fd, 0o600)
        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.acceptClient() }
        }
        source.resume()
        acceptSource = source
        Self.log.info("control socket listening at \(self.path, privacy: .public)")
    }

    func stop() {
        guard listenFD >= 0 else { return }
        acceptSource?.cancel()
        acceptSource = nil
        close(listenFD)
        listenFD = -1
        unlink(path)
        for client in clients.values {
            client.source.cancel()
        }
        clients = [:]
    }

    // MARK: Connections

    private func acceptClient() {
        let fd = accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.read(from: fd) }
        }
        source.setCancelHandler {
            close(fd)
        }
        clients[fd] = Client(source: source)
        source.resume()
    }

    private func read(from fd: Int32) {
        guard clients[fd] != nil else { return }
        var chunk = [UInt8](repeating: 0, count: 65536)
        let count = Darwin.read(fd, &chunk, chunk.count)
        guard count > 0 else {
            drop(fd)
            return
        }
        guard (clients[fd]?.buffer.count ?? 0) + count <= Self.maxLineBytes else {
            // A client streaming bytes without a newline would grow the
            // buffer forever; drop it past a generous line cap.
            respond(to: ControlProtocol.errorResponse(id: nil, error: .malformed), on: fd)
            drop(fd)
            return
        }
        clients[fd]?.buffer.append(chunk, count: count)
        while let client = clients[fd], let newline = client.buffer.firstIndex(of: 0x0A) {
            let line = client.buffer.subdata(in: client.buffer.startIndex..<newline)
            clients[fd]?.buffer.removeSubrange(client.buffer.startIndex...newline)
            respond(to: line, on: fd)
        }
    }

    /// Requests are one line; anything larger is not a request Tunnel Vision answers.
    private static let maxLineBytes = 1 << 20

    private func respond(to line: Data, on fd: Int32) {
        let response: Data
        if let request = ControlProtocol.parseRequest(line) {
            do {
                let result = try handler(request.method, request.params)
                response = ControlProtocol.response(id: request.id, result: result)
            } catch let error as ControlError {
                response = ControlProtocol.errorResponse(id: request.id, error: error)
            } catch {
                response = ControlProtocol.errorResponse(id: request.id, error: .refused(String(describing: error)))
            }
        } else {
            response = ControlProtocol.errorResponse(id: nil, error: .malformed)
        }
        response.withUnsafeBytes { bytes in
            var sent = 0
            while sent < bytes.count {
                guard let base = bytes.baseAddress else { return }
                let n = write(fd, base + sent, bytes.count - sent)
                guard n > 0 else { return }
                sent += n
            }
        }
    }

    private func drop(_ fd: Int32) {
        clients.removeValue(forKey: fd)?.source.cancel()
    }
}
