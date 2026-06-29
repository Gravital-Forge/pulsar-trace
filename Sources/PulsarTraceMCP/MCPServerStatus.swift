import Foundation

/// What the MCP server is doing right now (PT-P6-R11).
// PT-P6-R11
public enum MCPServerStatus: Sendable, Equatable {
    case stopped
    case running(port: UInt16)
    case portInUse(UInt16)
    case failed(String)
}

extension MCPServerStatus {
    /// The `/healthz` JSON body. The port is numeric so a health probe reads
    /// `port` as a number rather than a quoted string (PT-P6-R11).
    func healthzJSON() -> [String: Any] {
        switch self {
        case .stopped: return ["status": "stopped"]
        case .running(let port): return ["status": "running", "port": Int(port)]
        case .portInUse(let port): return ["status": "port_in_use", "port": Int(port)]
        case .failed(let reason): return ["status": "failed", "reason": reason]
        }
    }
}

/// A lock-guarded status cell the listener callback updates and `/healthz`
/// reads without hopping to the `MCPServer` actor.
final class MCPStatusBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: MCPServerStatus = .stopped
    var status: MCPServerStatus { lock.withLock { value } }
    func set(_ s: MCPServerStatus) { lock.withLock { value = s } }
}

/// The supervision policy (PT-P6-D10): rebuild a failed listener with bounded
/// backoff; never rotate on a bind failure (PT-P6-D3).
// PT-P6-R11
public enum MCPSupervisor {
    public static let maxAttempts = 5
    public static let maxBackoff: Duration = .seconds(30)

    /// Exponential backoff (1s, 2s, 4s, …) capped at `maxBackoff`.
    public static func backoffDelay(attempt: Int) -> Duration {
        let seconds = min(pow(2.0, Double(max(0, attempt - 1))), 30.0)
        return seconds >= 30.0 ? maxBackoff : .seconds(seconds)
    }
}
