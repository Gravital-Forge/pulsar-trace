import Testing
import Foundation
@testable import PulsarTraceMCP

@Suite("LoopbackHTTPListener")
struct LoopbackHTTPListenerTests {

    /// Spin up the listener on an ephemeral port and wait until it is ready.
    private func startEphemeral(
        _ handler: @escaping @Sendable (LoopbackHTTPRequest) async -> LoopbackHTTPResponse
    ) async throws -> (LoopbackHTTPListener, UInt16) {
        let listener = LoopbackHTTPListener(port: 0, handler: handler)
        try listener.start()
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if case .ready = listener.state, let port = listener.boundPort {
                return (listener, port)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        listener.stop()
        throw ListenerTestError.neverReady
    }

    enum ListenerTestError: Error { case neverReady }

    @Test("a POST body is parsed and the handler response is written back")
    func postRoundTrip() async throws {
        let (listener, port) = try await startEphemeral { req in
            if req.method == "POST" {
                return LoopbackHTTPResponse(status: 200, body: req.body)   // echo
            }
            return LoopbackHTTPResponse(status: 405, body: Data("no".utf8))
        }
        defer { listener.stop() }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        request.httpMethod = "POST"
        request.httpBody = Data("hello-mcp".utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self) == "hello-mcp")

        var get = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        get.httpMethod = "GET"
        let (_, getResponse) = try await URLSession.shared.data(for: get)
        #expect((getResponse as? HTTPURLResponse)?.statusCode == 405)
    }
}
