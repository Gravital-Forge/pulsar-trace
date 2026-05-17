import PulsarTraceMenuBar
import SwiftUI

/// The live-transcript popover (R40) — a read-only scroll of the lines
/// `LiveTranscriptWatcher` has tailed from `live.md`.
struct LiveTranscriptPopoverView: View {
    @Environment(LiveTranscriptWatcher.self) private var watcher
    /// Invoked by the "Back" button — inline navigation in `MenuBarMenuView`
    /// (FIX 2). Replaces `@Environment(\.dismiss)`, unreliable on a panel sheet.
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button { onClose() } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                Text("Live Transcript").font(.headline)
                Spacer()
            }
            .padding(12)
            Divider()

            if watcher.lines.isEmpty {
                Text("Waiting for transcript…")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(watcher.lines, id: \.self) { line in
                            Text(line).textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                }
            }
        }
        .frame(width: 420, height: 360)
    }
}
