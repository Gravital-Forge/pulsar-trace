import Foundation
import Network

/// A parsed HTTP/1.1 request. Header names are lowercased for case-insensitive
/// lookup.
public struct LoopbackHTTPRequest: Sendable {
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: Data

    /// Parse a complete request from the buffer, or return `nil` if more bytes
    /// are needed (headers not yet terminated, or body shorter than
    /// `Content-Length`).
    static func parse(_ buffer: Data) -> LoopbackHTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headEnd = buffer.range(of: separator) else { return nil }
        let head = String(decoding: buffer[..<headEnd.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }

        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        let method = String(requestLine[0])
        let rawTarget = String(requestLine[1])
        let path = String(rawTarget.split(separator: "?", maxSplits: 1).first ?? "")

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let bodyStart = headEnd.upperBound
        let available = buffer[bodyStart...]
        let expected = headers["content-length"].flatMap { Int($0) } ?? 0
        // A negative `Content-Length` is malformed, and `prefix(-1)` below
        // would trap — treat it like any other unparseable request (the idle
        // timeout reaps the connection).
        guard expected >= 0 else { return nil }
        guard available.count >= expected else { return nil }      // need more bytes
        let body = Data(available.prefix(expected))
        return LoopbackHTTPRequest(method: method, path: path, headers: headers, body: body)
    }

    /// The declared `Content-Length` once the header block is fully buffered, or
    /// `nil` if the headers are not yet terminated (or no length is present).
    /// Lets the listener reject an oversized body *before* buffering it
    /// (PT-P6-I1).
    static func declaredContentLength(_ buffer: Data) -> Int? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headEnd = buffer.range(of: separator) else { return nil }
        let head = String(decoding: buffer[..<headEnd.lowerBound], as: UTF8.self)
        for line in head.components(separatedBy: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard name == "content-length" else { continue }
            return Int(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
        return nil
    }
}

/// A response to serialize back to the socket. Always closes the connection.
public struct LoopbackHTTPResponse: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// A JSON response with the given top-level string fields.
    public static func json(_ status: Int, _ object: [String: String]) -> LoopbackHTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return LoopbackHTTPResponse(
            status: status, headers: ["Content-Type": "application/json"], body: data)
    }

    func serialized() -> Data {
        let reason = Self.reasons[status] ?? "OK"
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        var headers = self.headers
        headers["Content-Length"] = String(body.count)
        headers["Connection"] = "close"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        var out = Data(head.utf8)
        out.append(body)
        return out
    }

    private static let reasons: [Int: String] = [
        200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized",
        404: "Not Found", 405: "Method Not Allowed", 406: "Not Acceptable",
        413: "Request Entity Too Large", 415: "Unsupported Media Type",
        500: "Internal Server Error",
    ]
}

/// A loopback-only HTTP/1.1 listener (PT-P6-D2). Mirrors the teardown discipline
/// of the POSIX capture sockets (`@unchecked Sendable` + `NSLock`) but uses
/// `Network.framework` for the TCP/HTTP plumbing.
// PT-R115
public final class LoopbackHTTPListener: @unchecked Sendable {

    public typealias Handler = @Sendable (LoopbackHTTPRequest) async -> LoopbackHTTPResponse

    /// Hard cap on a single request (headers + body). Anything larger is
    /// refused with 413 *before* auth runs, so no local process can OOM the
    /// app with one giant `Content-Length` (PT-P6-I1).
    public static let maxRequestBytes = 4 * 1024 * 1024     // 4 MB

    /// Tear down a connection that has not produced a complete request within
    /// this window — a slowloris / half-open guard (PT-P6-I1).
    static let idleTimeout: TimeInterval = 15

    public enum ListenerState: Sendable, Equatable {
        case setup, ready, cancelled
        /// The port is not yet available; `addressInUse` is `true` when the
        /// cause is `EADDRINUSE` (the supervisor surfaces port-in-use rather
        /// than rotating — PT-P6-D3 / PT-P6-D10).
        case waiting(reason: String, addressInUse: Bool)
        case failed(reason: String, addressInUse: Bool)
    }

    private let requestedPort: NWEndpoint.Port
    private let handler: Handler
    private let maxRequestBytes: Int
    private let queue = DispatchQueue(label: "com.gravitalforge.PulsarTrace.mcp.listener")
    private let lock = NSLock()
    private var listener: NWListener?
    private var _state: ListenerState = .setup
    private var stateObserver: (@Sendable (ListenerState) -> Void)?

    public init(
        port: UInt16,
        maxRequestBytes: Int = LoopbackHTTPListener.maxRequestBytes,
        handler: @escaping Handler
    ) {
        self.requestedPort = NWEndpoint.Port(rawValue: port) ?? .any
        self.maxRequestBytes = maxRequestBytes
        self.handler = handler
    }

    /// Per-connection mutable state. `@unchecked Sendable` is sound for the same
    /// reason the listener is: `nw` is an immutable `Sendable` handle; `buffer`
    /// is touched only inside the receive callback chain, which `Network`
    /// delivers serially on `queue` (the next `receive` is issued only after the
    /// previous completion returns); and `finished` — which arbitrates the race
    /// between the in-flight response and the idle timer so a completed
    /// connection is never cancelled twice — is guarded by `lock`.
    private final class ConnectionContext: @unchecked Sendable {
        let nw: NWConnection
        var buffer = Data()
        var finished = false
        init(_ nw: NWConnection) { self.nw = nw }
    }

    public var state: ListenerState { lock.withLock { _state } }

    public var boundPort: UInt16? {
        lock.withLock { listener?.port?.rawValue }
    }

    public func onStateChange(_ observer: @escaping @Sendable (ListenerState) -> Void) {
        lock.withLock { stateObserver = observer }
    }

    public func start() throws {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback        // 127.0.0.1 only
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: requestedPort)
        listener.stateUpdateHandler = { [weak self] st in self?.handle(st) }
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        lock.withLock { self.listener = listener }
        listener.start(queue: queue)
    }

    public func stop() {
        let l: NWListener? = lock.withLock {
            let current = listener; listener = nil; _state = .cancelled; return current
        }
        l?.cancel()
    }

    private func setState(_ s: ListenerState) {
        let observer: (@Sendable (ListenerState) -> Void)? = lock.withLock {
            _state = s; return stateObserver
        }
        observer?(s)
    }

    private func handle(_ st: NWListener.State) {
        switch st {
        case .ready: setState(.ready)
        case .waiting(let e): setState(.waiting(reason: "\(e)", addressInUse: Self.isAddressInUse(e)))
        case .failed(let e): setState(.failed(reason: "\(e)", addressInUse: Self.isAddressInUse(e)))
        case .cancelled: setState(.cancelled)
        default: break
        }
    }

    private static func isAddressInUse(_ error: NWError) -> Bool {
        if case .posix(let code) = error { return code == .EADDRINUSE }
        return false
    }

    private func accept(_ conn: NWConnection) {
        let ctx = ConnectionContext(conn)
        conn.start(queue: queue)
        // Arm the idle timeout: if no complete request is handled within the
        // window, tear the connection down (PT-P6-I1). Captures `ctx` strongly
        // and `self` weakly; a no-op once the connection has finished.
        queue.asyncAfter(deadline: .now() + Self.idleTimeout) { [weak self] in
            guard let self, self.finish(ctx) else { return }
            ctx.nw.cancel()
        }
        receive(ctx)
    }

    /// Claim the connection's terminal transition. Returns `true` to the first
    /// caller (timer or response path); every later caller gets `false` and
    /// must not touch the connection again.
    private func finish(_ ctx: ConnectionContext) -> Bool {
        lock.withLock {
            if ctx.finished { return false }
            ctx.finished = true
            return true
        }
    }

    private func receive(_ ctx: ConnectionContext) {
        ctx.nw.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { ctx.nw.cancel(); return }
            if let data { ctx.buffer.append(data) }

            // Refuse an oversized request *before* it is fully buffered or auth
            // runs — a declared `Content-Length` over the cap, or raw bytes
            // already over the cap, both yield a 413 (PT-P6-I1).
            if self.exceedsCap(ctx.buffer) {
                guard self.finish(ctx) else { return }
                ctx.nw.send(
                    content: LoopbackHTTPResponse(
                        status: 413, body: Data("Request Entity Too Large".utf8)).serialized(),
                    completion: .contentProcessed { _ in ctx.nw.cancel() })
                return
            }

            if let request = LoopbackHTTPRequest.parse(ctx.buffer) {
                guard self.finish(ctx) else { return }
                Task {
                    let response = await self.handler(request)
                    ctx.nw.send(content: response.serialized(),
                                completion: .contentProcessed { _ in ctx.nw.cancel() })
                }
                return
            }
            if isComplete || error != nil { ctx.nw.cancel(); return }
            self.receive(ctx)
        }
    }

    /// `true` when the buffer (or its declared body) exceeds `maxRequestBytes`.
    private func exceedsCap(_ buffer: Data) -> Bool {
        if buffer.count > maxRequestBytes { return true }
        if let declared = LoopbackHTTPRequest.declaredContentLength(buffer),
           declared > maxRequestBytes { return true }
        return false
    }
}
