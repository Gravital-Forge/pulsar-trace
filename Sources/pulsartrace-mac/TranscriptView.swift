import AppKit
import SwiftUI

/// A read-only scrolling transcript display (#4).
///
/// Shared by the detached live-transcript window (lines tailed from `live.md`)
/// and the recorded-transcript viewer (lines read once from `final.md`). The
/// two callers differ only in their data source; the rendering is identical.
struct TranscriptView: View {
    /// The transcript lines, in file order.
    let lines: [String]
    /// Shown when `lines` is empty.
    var placeholder: String = "No transcript yet."

    var body: some View {
        if lines.isEmpty {
            Text(placeholder)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                // One `Text` for the whole transcript, not one per line, so a
                // text selection can span multiple lines (a per-line `Text`
                // confines the selection to a single line).
                Text(lines.joined(separator: "\n"))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
    }
}

/// Copy a transcript's lines to the general pasteboard — backs the "Copy"
/// button in the live and recorded transcript views (#4).
@MainActor
func copyTranscriptToPasteboard(_ lines: [String]) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(lines.joined(separator: "\n"), forType: .string)
}
