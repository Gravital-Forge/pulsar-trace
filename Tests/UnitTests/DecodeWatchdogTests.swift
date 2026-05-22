import Testing
import Foundation
import Logging
@testable import PulsarTraceEngine

@Suite("DecodeWatchdog")
struct DecodeWatchdogTests {

    @Test("cancels the in-flight token once the decode passes the deadline")
    func cancelsAfterDeadline() async {
        let dog = DecodeWatchdog(
            deadline: .milliseconds(80), abortGrace: .seconds(10),
            logger: .init(label: "test"))
        let token = AbortToken()
        await dog.beginDecode(token: token, stream: "system")
        #expect(token.isCancelled == false)
        try? await Task.sleep(for: .milliseconds(250))
        #expect(token.isCancelled == true)
        await dog.endDecode()
    }

    @Test("does not cancel a decode that finishes before the deadline")
    func noCancelWhenFast() async {
        let dog = DecodeWatchdog(
            deadline: .seconds(5), abortGrace: .seconds(10),
            logger: .init(label: "test"))
        let token = AbortToken()
        await dog.beginDecode(token: token, stream: "system")
        try? await Task.sleep(for: .milliseconds(50))
        await dog.endDecode()
        try? await Task.sleep(for: .milliseconds(120))
        #expect(token.isCancelled == false)
    }

    @Test("warns with a growing age when a decode ignores the abort past the grace window")
    func warnsWhenAbortNotHonored() async {
        let capture = CapturingLogHandler()
        let logger = Logger(label: "test") { _ in capture }
        let dog = DecodeWatchdog(
            deadline: .milliseconds(50), abortGrace: .milliseconds(80),
            logger: logger)
        let token = AbortToken()   // nothing ever acts on it (simulated hang)
        await dog.beginDecode(token: token, stream: "mic")
        try? await Task.sleep(for: .milliseconds(400))
        await dog.endDecode()
        let warnings = capture.messages.filter { $0.contains("did not honor abort") }
        #expect(warnings.count >= 2, "expected escalating warnings; got \(capture.messages)")
        let ages = warnings.compactMap { Self.age(from: $0) }
        for i in 1..<ages.count { #expect(ages[i] >= ages[i-1]) }
    }

    private static func age(from m: String) -> Int? {
        guard let r = m.range(of: #"age=([0-9]+)ms"#, options: .regularExpression)
        else { return nil }
        return Int(m[r].dropFirst("age=".count).dropLast(2))
    }
}

/// Lock-protected log sink recording every message (for asserting log content).
private final class CapturingLogHandler: LogHandler, @unchecked Sendable {
    private let lock = NSLock(); private var _m: [String] = []
    var logLevel: Logger.Level = .trace
    var metadata: Logger.Metadata = [:]
    subscript(metadataKey k: String) -> Logger.Metadata.Value? {
        get { metadata[k] } set { metadata[k] = newValue } }
    var messages: [String] { lock.withLock { _m } }
    func log(level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?,
             source: String, file: String, function: String, line: UInt) {
        lock.withLock { _m.append("\(message)") }
    }
}
