import Foundation

/// Probe the loopback `/healthz` endpoint so Settings reflects whether the
/// socket is truly accepting — not just an in-memory flag (PT-P6-D10). The
/// port is serialized as a numeric `Int` (PT-P6-R11), so it is parsed as one.
public enum MCPHealthProbe {
    public static func probe(port: UInt16, timeout: TimeInterval = 1.0) async -> MCPServerStatus {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/healthz")!)
        request.timeoutInterval = timeout
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = json["status"] as? String else {
            return .stopped
        }
        switch status {
        case "running": return .running(port: (json["port"] as? Int).map(UInt16.init) ?? port)
        case "port_in_use": return .portInUse(port)
        case "failed": return .failed(json["reason"] as? String ?? "unknown")
        default: return .stopped
        }
    }
}
