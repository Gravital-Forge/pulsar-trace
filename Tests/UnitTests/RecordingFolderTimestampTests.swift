// Tests/UnitTests/RecordingFolderTimestampTests.swift
import Foundation
import Testing
@testable import PulsarTraceEngine

@Suite("RecordingFolderTimestamp")
struct RecordingFolderTimestampTests {

    @Test("parses a bare yyyy-MM-dd-HHmmss prefix")
    func parsesBarePrefix() throws {
        let date = try #require(
            RecordingFolderTimestamp.parse("2026-05-20-100033"))
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date)
        #expect(comps.year == 2026)
        #expect(comps.month == 5)
        #expect(comps.day == 20)
        #expect(comps.hour == 10)
        #expect(comps.minute == 0)
        #expect(comps.second == 33)
    }

    @Test("only matches yyyy-MM-dd-HHmmss prefixes, not yyyy-MM-dd-<slug>")
    func rejectsDateOnlyPrefix() {
        // The menubar always writes the time component (HHmmss). A
        // dev-named folder like "2026-04-30-team-standup" is not a
        // menubar recording, so parse must reject it.
        #expect(RecordingFolderTimestamp.parse("2026-04-30-team-standup") == nil)
    }

    @Test("returns nil when the prefix is not yyyy-MM-dd-HHmmss")
    func nilOnNoTimestamp() {
        #expect(RecordingFolderTimestamp.parse("meeting") == nil)
        #expect(RecordingFolderTimestamp.parse("") == nil)
        #expect(RecordingFolderTimestamp.parse("2026-05-20") == nil)
    }

    @Test("preserves a yyyy-MM-dd-HHmmss prefix even when more text follows")
    func parsesPrefixWithTrailing() throws {
        let date = try #require(
            RecordingFolderTimestamp.parse("2026-05-20-100033-debug"))
        let cal = Calendar(identifier: .gregorian)
        #expect(cal.component(.hour, from: date) == 10)
        #expect(cal.component(.second, from: date) == 33)
    }
}
