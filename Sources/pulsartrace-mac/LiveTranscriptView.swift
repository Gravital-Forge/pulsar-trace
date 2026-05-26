import PulsarTraceMenuBar
import SwiftUI

/// The detached live-transcript window (#5, R40) — a read-only scroll of the
/// lines `LiveTranscriptWatcher` has tailed from `live.md`.
///
/// Hosted in its own `Window` scene (`WindowID.liveTranscript`) so it stays
/// visible when the user clicks away — it is no longer an inline page in the
/// menubar panel. The watcher lives at app scope and keeps tailing whether or
/// not this window is open, so re-opening just re-shows the already-tailed
/// lines.
///
/// Smart auto-scroll (R45): a view-scoped `AutoScrollController` follows the
/// latest line while the user is at/near the bottom, pauses when they scroll
/// up, and surfaces a "Jump to latest" pill until they return.
struct LiveTranscriptView: View {
    @Environment(LiveTranscriptWatcher.self) private var watcher

    /// View-scoped — a fresh controller per window open. `@State` keeps the
    /// instance alive across view re-renders; `@Observable` makes its mutations
    /// trigger re-renders without needing `@Bindable`.
    @State private var autoScroll = AutoScrollController()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Live Transcript").font(.headline)
                if watcher.isActive {
                    Label("Recording", systemImage: "circle.fill")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
                Spacer()
                Button {
                    copyTranscriptToPasteboard(watcher.lines)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .disabled(watcher.lines.isEmpty)
            }
            .padding(12)
            Divider()

            TranscriptView(
                lines: watcher.lines,
                placeholder: watcher.isActive
                    ? "Waiting for transcript…"
                    : "No recording in progress.",
                autoScroll: autoScroll)
        }
        .frame(minWidth: 360, minHeight: 320)
    }
}
