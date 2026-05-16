import Testing
import Foundation
@testable import PulsarTraceEngine

/// Layer 1 — `EventLogTail`, the pure parsing/filtering behind
/// `pulsartrace events tail` (R86). No timer, no follow loop here: those live
/// in the CLI command and are covered by a real-binary smoke run.
@Suite("EventLogTail (events tail, R86)")
struct EventLogTailTests {

    private let sampleLine =
        #"{"id":"evt_01","ts":"2026-05-16T03:26:32Z","type":"refinement_started","version":1}"#

    // MARK: - eventType(of:)

    @Test("a well-formed JSONL line yields its type")
    func eventTypeOfValidLine() {
        #expect(EventLogTail.eventType(of: sampleLine) == "refinement_started")
    }

    @Test("blank and non-JSON lines yield no type")
    func eventTypeOfNoise() {
        #expect(EventLogTail.eventType(of: "") == nil)
        #expect(EventLogTail.eventType(of: "   ") == nil)
        #expect(EventLogTail.eventType(of: "not json") == nil)
        #expect(EventLogTail.eventType(of: "[1,2,3]") == nil)
    }

    @Test("a JSON object without a string type yields no type")
    func eventTypeMissingField() {
        #expect(EventLogTail.eventType(of: #"{"id":"evt_01"}"#) == nil)
        #expect(EventLogTail.eventType(of: #"{"type":42}"#) == nil)
    }

    // MARK: - lineMatches

    @Test("an empty filter passes every well-formed event line")
    func lineMatchesNoFilter() {
        #expect(EventLogTail.lineMatches(sampleLine, types: []))
    }

    @Test("a non-empty filter keeps only members and drops the rest")
    func lineMatchesWithFilter() {
        #expect(EventLogTail.lineMatches(sampleLine, types: ["refinement_started"]))
        #expect(EventLogTail.lineMatches(
            sampleLine, types: ["refinement_started", "app_started"]))
        #expect(!EventLogTail.lineMatches(sampleLine, types: ["app_started"]))
    }

    @Test("a line with no parseable type never matches, filter or not")
    func lineMatchesDropsNoise() {
        #expect(!EventLogTail.lineMatches("", types: []))
        #expect(!EventLogTail.lineMatches("garbage", types: []))
        #expect(!EventLogTail.lineMatches("garbage", types: ["app_started"]))
    }

    // MARK: - splitLines

    @Test("complete lines are split off and a trailing partial is carried over")
    func splitLinesPartialTail() {
        let (lines, remainder) = EventLogTail.splitLines("a\nb\nhalf")
        #expect(lines == ["a", "b"])
        #expect(remainder == "half")
    }

    @Test("text with no newline is all remainder")
    func splitLinesNoNewline() {
        let (lines, remainder) = EventLogTail.splitLines("partial")
        #expect(lines.isEmpty)
        #expect(remainder == "partial")
    }

    @Test("a trailing newline leaves an empty remainder")
    func splitLinesCleanBoundary() {
        let (lines, remainder) = EventLogTail.splitLines("a\nb\n")
        #expect(lines == ["a", "b"])
        #expect(remainder == "")
    }

    // MARK: - currentFileURL

    @Test("currentFileURL is today's UTC-dated jsonl, matching EventWriter")
    func currentFileURLMatchesWriterNaming() {
        let dir = URL(fileURLWithPath: "/tmp/events", isDirectory: true)
        var c = DateComponents()
        c.year = 2026; c.month = 5; c.day = 16; c.hour = 23
        c.timeZone = TimeZone(identifier: "UTC")
        let date = Calendar(identifier: .gregorian).date(from: c)!
        let tail = EventLogTail(directory: dir, clock: { date })
        #expect(tail.currentFileURL().lastPathComponent == "2026-05-16.jsonl")
    }
}
