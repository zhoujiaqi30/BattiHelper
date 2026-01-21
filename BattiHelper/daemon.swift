import Foundation
import Dispatch
import Darwin

private let daemonLogScope = "daemon"

// Unix-domain-socket daemon runtime.
//
// Protocol:
// - Client sends one JSON object per line (newline-delimited JSON / NDJSON).
// - Server replies with one JSON object per line.
// - Messages are framed by '\n' (0x0A). There is no length prefix.
//
// Shutdown:
// - A `.stop` request triggers a graceful exit: the server sends the response
//   first, then signals the run loop to stop.
// - SIGINT/SIGTERM also stop the run loop.

enum DaemonEvent: String, Codable {
    // Liveness check.
    case ping
    // Force charging behavior.
    case charge
    // Force discharging behavior.
    case discharge
    // Restore system defaults.
    case resetDefault
    // Query current state.
    case status
    // Request server shutdown.
    case stop
}

struct DaemonRequest: Codable {
    // Optional request id for client-side correlation.
    var id: String?
    // Operation type.
    var event: DaemonEvent
    // Optional payload (currently unused by the daemon).
    var payload: [String: String]?
}

struct DaemonResponse: Codable {
    // Mirrors request id when present.
    var id: String?
    // Indicates success/failure at the daemon level.
    var ok: Bool
    // Mirrors request event.
    var event: DaemonEvent
    // Optional small string map result.
    var result: [String: String]?
    // Optional error string for clients.
    var error: String?
}

enum DaemonService {
    // Runs the socket server until `.stop` is received or SIGINT/SIGTERM arrives.
    // The handler must be fast; it runs on the daemon's internal serial queue.
    static func run(
        socketPath: String,
        handler: @escaping (DaemonRequest) -> DaemonResponse
    ) throws {
        Log.info("daemon_start socket=\(socketPath)", scope: daemonLogScope)
        let exitSignal = DispatchSemaphore(value: 0)
        let server = UnixSocketServer(socketPath: socketPath)
        server.onRequest = handler
        server.onStopRequested = {
            Log.info("daemon_stop_requested", scope: daemonLogScope)
            exitSignal.signal()
        }
        
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        
        let sigIntSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        let sigTermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        sigIntSource.setEventHandler {
            Log.info("daemon_signal sig=SIGINT", scope: daemonLogScope)
            exitSignal.signal()
        }
        sigTermSource.setEventHandler {
            Log.info("daemon_signal sig=SIGTERM", scope: daemonLogScope)
            exitSignal.signal()
        }
        sigIntSource.resume()
        sigTermSource.resume()
        
        try server.start()
        exitSignal.wait()
        
        sigIntSource.cancel()
        sigTermSource.cancel()
        server.stop()
        Log.info("daemon_stopped", scope: daemonLogScope)
    }
}

private final class UnixSocketServer {
    private final class Connection {
        private let fd: Int32
        private var source: DispatchSourceRead?
        private var buffer = Data()
        private let queue: DispatchQueue
        private let onLine: (Data) -> Void
        private let onClose: (Int32) -> Void
        
        init(
            fd: Int32,
            queue: DispatchQueue,
            onLine: @escaping (Data) -> Void,
            onClose: @escaping (Int32) -> Void
        ) {
            self.fd = fd
            self.queue = queue
            self.onLine = onLine
            self.onClose = onClose
        }
        
        func start() {
            // We use a DispatchSourceRead to integrate the socket with GCD.
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in
                guard let self else { return }
                self.readAvailable()
            }
            source.setCancelHandler { [fd] in
                // Closing the FD here guarantees resources are released once the
                // source is cancelled.
                close(fd)
            }
            self.source = source
            source.resume()
        }
        
        func stop() {
            source?.cancel()
            source = nil
        }
        
        private func readAvailable() {
            // Read until EAGAIN/EWOULDBLOCK to drain the socket.
            var tmp = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = recv(fd, &tmp, tmp.count, 0)
                if n > 0 {
                    buffer.append(tmp, count: n)
                    drainLines()
                    continue
                }
                
                if n == 0 {
                    // Peer closed the connection.
                    onClose(fd)
                    return
                }
                
                let err = errno
                if err == EAGAIN || err == EWOULDBLOCK {
                    // No more data available right now.
                    return
                }
                
                // Any other error: close the connection.
                onClose(fd)
                return
            }
        }
        
        private func drainLines() {
            // Frame by '\n' and deliver one logical message at a time.
            while let idx = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<idx)
                buffer.removeSubrange(buffer.startIndex...idx)
                if line.isEmpty { continue }
                onLine(line)
            }
        }
    }
    
    let socketPath: String
    
    private let queue = DispatchQueue(label: "battihelper.socket.server")
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private var listenFD: Int32 = -1
    private var listenSource: DispatchSourceRead?
    private var connections: [Int32: Connection] = [:]
    
    var onRequest: ((DaemonRequest) -> DaemonResponse)?
    var onStopRequested: (() -> Void)?
    
    init(socketPath: String) {
        self.socketPath = socketPath
        encoder.outputFormatting = []
    }
    
    func start() throws {
        // Avoid crashing on writes to a closed socket.
        signal(SIGPIPE, SIG_IGN)
        
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            Log.error("socket_create_failed errno=\(errno)", scope: daemonLogScope)
            throw NSError(domain: "UnixSocketServer", code: Int(errno))
        }
        listenFD = fd
        
        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        let socketDir = URL(fileURLWithPath: socketPath).deletingLastPathComponent().path
        do {
            try FileManager.default.createDirectory(atPath: socketDir, withIntermediateDirectories: true)
        } catch {
            Log.error("socket_dir_create_failed path=\(socketDir) error=\(error)", scope: daemonLogScope)
            throw error
        }
        
        // Remove stale socket file from a previous run.
        unlink(socketPath)
        
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPathBytes = MemoryLayout.size(ofValue: addr.sun_path)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= maxPathBytes else {
            Log.error("socket_path_too_long len=\(pathBytes.count) max=\(maxPathBytes)", scope: daemonLogScope)
            throw NSError(domain: "UnixSocketServer", code: 2)
        }
        pathBytes.withUnsafeBufferPointer { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path.0) { sunPathPtr in
                sunPathPtr.withMemoryRebound(to: CChar.self, capacity: maxPathBytes) { ccharPtr in
                    _ = strncpy(ccharPtr, ptr.baseAddress, maxPathBytes)
                }
            }
        }
        
        let addrLen = socklen_t(MemoryLayout.size(ofValue: addr))
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                Darwin.bind(fd, rebound, addrLen)
            }
        }
        guard bindResult == 0 else {
            Log.error("socket_bind_failed errno=\(errno)", scope: daemonLogScope)
            throw NSError(domain: "UnixSocketServer", code: Int(errno))
        }
        
        guard listen(fd, 64) == 0 else {
            Log.error("socket_listen_failed errno=\(errno)", scope: daemonLogScope)
            throw NSError(domain: "UnixSocketServer", code: Int(errno))
        }
        
        Log.info("socket_listening path=\(socketPath)", scope: daemonLogScope)
        
        // Listen FD is non-blocking; accept on readiness notifications.
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptAvailable()
        }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.listenFD >= 0 {
                close(self.listenFD)
                self.listenFD = -1
            }
            // Ensure the socket file is removed when stopping.
            unlink(self.socketPath)
        }
        listenSource = source
        source.resume()
    }
    
    func stop() {
        queue.sync {
            for (_, conn) in connections {
                conn.stop()
            }
            connections.removeAll()
            listenSource?.cancel()
            listenSource = nil
        }
    }
    
    private func sendLine(fd: Int32, data: Data) {
        // Append '\n' to preserve the NDJSON framing.
        var out = data
        out.append(0x0A)
        
        out.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return }
            var remaining = rawBuf.count
            var ptr = base.assumingMemoryBound(to: UInt8.self)
            
            while remaining > 0 {
                let n = send(fd, ptr, remaining, 0)
                if n > 0 {
                    remaining -= n
                    ptr = ptr.advanced(by: n)
                    continue
                }
                
                let err = errno
                if err == EAGAIN || err == EWOULDBLOCK {
                    // Socket send buffer is full; drop remaining data.
                    break
                }
                
                break
            }
        }
    }
    
    private func acceptAvailable() {
        while true {
            var addr = sockaddr()
            var len: socklen_t = socklen_t(MemoryLayout.size(ofValue: addr))
            let clientFD = accept(listenFD, &addr, &len)
            if clientFD < 0 {
                let err = errno
                if err == EAGAIN || err == EWOULDBLOCK {
                    return
                }
                Log.error("socket_accept_failed errno=\(err)", scope: daemonLogScope)
                return
            }
            
            Log.debug("socket_client_connected fd=\(clientFD)", scope: daemonLogScope)
            
            let flags = fcntl(clientFD, F_GETFL, 0)
            _ = fcntl(clientFD, F_SETFL, flags | O_NONBLOCK)
            
            let conn = Connection(
                fd: clientFD,
                queue: queue,
                onLine: { [weak self] line in self?.handleLine(fd: clientFD, line: line) },
                onClose: { [weak self] fd in self?.removeConnection(fd: fd) }
            )
            connections[clientFD] = conn
            conn.start()
        }
    }
    
    private func removeConnection(fd: Int32) {
        if let conn = connections.removeValue(forKey: fd) {
            conn.stop()
        }
        Log.debug("socket_client_disconnected fd=\(fd)", scope: daemonLogScope)
    }
    
    private func handleLine(fd: Int32, line: Data) {
        func sendResponse(_ resp: DaemonResponse) {
            if let data = try? encoder.encode(resp) {
                sendLine(fd: fd, data: data)
            }
        }
        
        let request: DaemonRequest
        do {
            request = try decoder.decode(DaemonRequest.self, from: line)
        } catch {
            // Malformed JSON: respond with a generic error.
            Log.warn("invalid_request fd=\(fd)", scope: daemonLogScope)
            sendResponse(DaemonResponse(id: nil, ok: false, event: .ping, result: nil, error: "invalid_request"))
            return
        }
        
        Log.debug("request fd=\(fd) event=\(request.event.rawValue) id=\(request.id ?? "")", scope: daemonLogScope)
        
        guard let handler = onRequest else {
            sendResponse(DaemonResponse(id: request.id, ok: false, event: request.event, result: nil, error: "no_handler"))
            return
        }
        
        sendResponse(handler(request))
        
        if request.event == .stop {
            // Stop is handled after responding so the client can read the final reply.
            onStopRequested?()
        }
    }
}
