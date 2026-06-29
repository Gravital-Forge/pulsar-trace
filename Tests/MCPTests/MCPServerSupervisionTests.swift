import Testing
import Foundation
@testable import PulsarTraceMCP

@Suite("MCPServerSupervision")
struct MCPServerSupervisionTests {

    enum TestError: Error { case neverBound }

    private func auth() -> MCPAuth {
        MCPAuth(tokenURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-mcp-\(UUID().uuidString)").appendingPathComponent("tok"))
    }

    private func waitForPort(_ server: MCPServer) async throws -> UInt16 {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if let p = await server.boundPort() { return p }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw TestError.neverBound
    }

    @Test("/healthz reports running with the bound port")
    func healthzReportsRunning() async throws {
        let server = MCPServer(port: 0, auth: auth())
        try await server.start()
        let port = try await waitForPort(server)
        defer { Task { await server.stop() } }
        try await Task.sleep(for: .milliseconds(100))

        let (data, _) = try await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:\(port)/healthz")!)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["status"] as? String == "running")
        #expect((json?["port"] as? Int).map(UInt16.init) == port)
    }

    @Test("a second server on the same port reports port-in-use and does not rotate")
    func portInUseIsSurfaced() async throws {
        let first = MCPServer(port: 0, auth: auth())
        try await first.start()
        let port = try await waitForPort(first)
        defer { Task { await first.stop() } }
        try await Task.sleep(for: .milliseconds(100))

        let second = MCPServer(port: port, auth: auth())
        try await second.start()
        defer { Task { await second.stop() } }
        try await Task.sleep(for: .milliseconds(300))

        let status = await second.status
        #expect(status == .portInUse(port))
        #expect(await second.boundPort() == nil)
        #expect(await first.status == .running(port: port))
    }

    @Test("backoff grows with the attempt and is capped")
    func backoffGrowsAndCaps() {
        let d1 = MCPSupervisor.backoffDelay(attempt: 1)
        let d2 = MCPSupervisor.backoffDelay(attempt: 2)
        let dBig = MCPSupervisor.backoffDelay(attempt: 99)
        #expect(d2 > d1)
        #expect(dBig == MCPSupervisor.maxBackoff)
    }
}
