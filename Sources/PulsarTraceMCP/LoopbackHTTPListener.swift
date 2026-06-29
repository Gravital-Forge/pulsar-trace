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
        guard available.count >= expected else { return nil }      // need more bytes
        let body = Data(available.prefix(expected))
        return LoopbackHTTPRequest(method: method, path: path, headers: headers, body: body)
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
        415: "Unsupported Media Type", 500: "Internal Server Error",
    ]
}

/// A loopback-only HTTP/1.1 listener (PT-P6-D2). Mirrors the teardown discipline
/// of the POSIX capture sockets (`@unchecked Sendable` + `NSLock`) but uses
/// `Network.framework` for the TCP/HTTP plumbing.
// PT-P6-R1
public final class LoopbackHTTPListener: @unchecked Sendable {

    public typealias Handler = @Sendable (LoopbackHTTPRequest) async -> LoopbackHTTPResponse

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
    private let queue = DispatchQueue(label: "com.gravitalforge.PulsarTrace.mcp.listener")
    private let lock = NSLock()
    private var listener: NWListener?
    private var _state: ListenerState = .setup
    private var stateObserver: (@Sendable (ListenerState) -> Void)?

    public init(port: UInt16, handler: @escaping Handler) {
        self.requestedPort = NWEndpoint.Port(rawValue: port) ?? .any
        self.handler = handler
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
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = LoopbackHTTPRequest.parse(buffer) {
                Task {
                    let response = await self.handler(request)
                    conn.send(content: response.serialized(),
                              completion: .contentProcessed { _ in conn.cancel() })
                }
                return
            }
            if isComplete || error != nil { conn.cancel(); return }
            self.receive(conn, buffer: buffer)
        }
    }
}
