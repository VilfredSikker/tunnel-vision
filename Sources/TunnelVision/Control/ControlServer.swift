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
        /// Answer bytes the socket did not take yet; sent when it can.
        var pending = Data()
        var writeSource: DispatchSourceWrite?
        /// The client closed its side after its requests; the connection
        /// ends once `pending` is out. The read source is suspended so the
        /// end-of-file does not fire again meanwhile.
        var closing = false
    }

    /// A client more than this far behind on reading its answers is dropped.
    private static let maxPendingBytes = 16 << 20

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
        // Writing to a client that hung up raises SIGPIPE, which would kill
        // the app with apps still frozen. SO_NOSIGPIPE per client is not
        // enough: macOS refuses it (EINVAL) on a socket whose peer is
        // already gone, the exact case it exists for.
        signal(SIGPIPE, SIG_IGN)
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
        // fchmod on a socket descriptor leaves the path's mode alone; the
        // path itself has to be changed.
        chmod(path, 0o600)
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
        for fd in Array(clients.keys) {
            drop(fd)
        }
    }

    // MARK: Connections

    private func acceptClient() {
        let fd = accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        // Belt and braces with the SIG_IGN in start(). Non-blocking, so a
        // client that stops reading cannot stall the main queue.
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
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
        if count < 0, errno == EAGAIN || errno == EINTR { return }
        if count == 0, let client = clients[fd], !client.pending.isEmpty, !client.closing {
            // A half-close after the request (`nc -N`, most scripts): the
            // answer still goes out, then the connection ends.
            clients[fd]?.closing = true
            client.source.suspend()
            return
        }
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
        guard clients[fd] != nil else { return }
        clients[fd]?.pending.append(response)
        guard (clients[fd]?.pending.count ?? 0) <= Self.maxPendingBytes else {
            drop(fd)
            return
        }
        flush(fd)
    }

    /// Sends what the socket takes now. An answer bigger than the socket
    /// buffer (about 8 KB) comes back as EAGAIN partway; the rest goes out
    /// from a write source when the client has read some, so the main queue
    /// never blocks on a slow reader.
    private func flush(_ fd: Int32) {
        guard var client = clients[fd] else { return }
        while !client.pending.isEmpty {
            let n = client.pending.withUnsafeBytes { bytes in
                write(fd, bytes.baseAddress, bytes.count)
            }
            if n > 0 {
                client.pending.removeSubrange(client.pending.startIndex..<client.pending.startIndex + n)
                continue
            }
            if n < 0, errno == EINTR { continue }
            if n < 0, errno == EAGAIN {
                if client.writeSource == nil {
                    let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: .main)
                    source.setEventHandler { [weak self] in
                        MainActor.assumeIsolated { self?.flush(fd) }
                    }
                    client.writeSource = source
                    clients[fd] = client
                    source.resume()
                } else {
                    clients[fd] = client
                }
                return
            }
            // Gone (EPIPE) or failed.
            clients[fd] = client
            drop(fd)
            return
        }
        client.writeSource?.cancel()
        client.writeSource = nil
        clients[fd] = client
        if client.closing {
            drop(fd)
        }
    }

    private func drop(_ fd: Int32) {
        guard let client = clients.removeValue(forKey: fd) else { return }
        // The write source first: the read source's cancel closes the fd.
        client.writeSource?.cancel()
        client.source.cancel()
        if client.closing {
            // A suspended source runs its cancel handler (the close) only
            // once resumed.
            client.source.resume()
        }
    }
}
