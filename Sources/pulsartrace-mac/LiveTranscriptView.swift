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

    /// Bridges the toolbar Find button / ⌘F to the renderer's find bar.
    @State private var find = TranscriptFindActivator()

    var body: some View {
        TranscriptView(
            lines: watcher.lines,
            placeholder: watcher.isActive
                ? "Waiting for transcript…"
                : "No recording in progress.",
            autoScroll: autoScroll,
            findActivator: find)
        .frame(minWidth: 360, minHeight: 320)
        // Same launch-quiet rule as the main window (see
        // `WindowRestorationOptOut`): never re-presented by restoration.
        .background(WindowRestorationOptOut())
        .navigationTitle("Live Transcript")
        .toolbar {
            // Conditionally PRESENT, not a conditionally-empty item: an empty
            // ToolbarItem draws a ghost button (regression fixed in 55ec1b8).
            if watcher.isActive {
                ToolbarItem {
                    Label("Recording", systemImage: "circle.fill")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.red)
                        .font(.caption)
                        // Breathing room inside the toolbar-item chrome —
                        // without it the dot touches the item's leading edge
                        // (QA rounds 5 and 8: 6pt still read as tight).
                        .padding(.horizontal, 10)
                        .accessibilityLabel("Recording in progress")
                }
            }
            ToolbarItem {
                Button {
                    find.showFind()
                } label: {
                    Label("Find", systemImage: "magnifyingglass")
                }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(watcher.lines.isEmpty)
                .help("Find in transcript (⌘F)")
            }
            ToolbarItem {
                Button {
                    copyTranscriptToPasteboard(watcher.lines)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .disabled(watcher.lines.isEmpty)
                .help("Copy the transcript text")
            }
        }
    }
}
