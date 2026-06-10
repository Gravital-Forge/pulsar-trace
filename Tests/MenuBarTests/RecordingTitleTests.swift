import Foundation
import Testing
@testable import PulsarTraceMenuBar

@Suite("RecordingEntry.displayTitle")
struct RecordingTitleTests {
    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi
        return Calendar.current.date(from: c)!
    }

    @Test("a recording from today reads 'Today at <time>'")
    func today() {
        let now = Date()
        let title = RecordingEntry.displayTitle(for: now, relativeTo: now)
        #expect(title.hasPrefix("Today at "))
    }

    @Test("a recording from yesterday reads 'Yesterday at <time>'")
    func yesterday() {
        let now = date(2026, 6, 10, 9, 0)
        let start = date(2026, 6, 9, 14, 30)
        let title = RecordingEntry.displayTitle(for: start, relativeTo: now)
        #expect(title.hasPrefix("Yesterday at "))
    }

    @Test("an older recording is locale-formatted with its year")
    func older() {
        let start = date(2026, 5, 16, 14, 30)
        let ref = date(2026, 6, 10, 9, 0)
        let title = RecordingEntry.displayTitle(for: start, relativeTo: ref)
        #expect(!title.hasPrefix("Today"))
        #expect(!title.hasPrefix("Yesterday"))
        #expect(title.contains("2026"))
    }
}
