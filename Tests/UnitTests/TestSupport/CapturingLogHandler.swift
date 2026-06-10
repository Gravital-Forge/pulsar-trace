import Foundation
import Logging

/// Lock-protected log sink shared by every suite that asserts on log
/// content. Implements the current `log(event:)` requirement directly —
/// the per-file copies this replaces all leaned on swift-log's deprecated
/// forwarding shim and warned on every build.
final class CapturingLogHandler: LogHandler, @unchecked Sendable {
    private let lock = NSLock()
    private var _messages: [String] = []
    var messages: [String] { lock.withLock { _messages } }

    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .trace
    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        lock.withLock { _messages.append(event.message.description) }
    }
}
