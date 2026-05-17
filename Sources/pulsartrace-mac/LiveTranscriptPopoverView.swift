import PulsarTraceMenuBar
import SwiftUI

/// The live-transcript popover (R40) — a read-only scroll of the lines
/// `LiveTranscriptWatcher` has tailed from `live.md`.
struct LiveTranscriptPopoverView: View {
    @Environment(LiveTranscriptWatcher.self) private var watcher
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Live Transcript").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
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
