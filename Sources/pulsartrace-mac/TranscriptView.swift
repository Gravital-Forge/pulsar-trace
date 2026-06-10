import AppKit
import PulsarTraceMenuBar
import SwiftUI

/// A read-only scrolling transcript display (#4).
///
/// Shared by the detached live-transcript window (lines tailed from `live.md`)
/// and the recorded-transcript viewer (lines read once from `final.md`). The
/// two callers differ in their data source and in whether they pass an
/// `AutoScrollController` — when one is provided, the view runs the smart
/// auto-scroll behavior (R45); when it is `nil`, the static path is used.
struct TranscriptView: View {
    /// The transcript lines, in file order.
    let lines: [String]
    /// Shown when `lines` is empty.
    var placeholder: String = "No transcript yet."
    /// Opt-in smart auto-scroll. The live-transcript window passes one of
    /// these; the recorded-transcript viewer passes `nil` and gets a plain
    /// scroll view.
    var autoScroll: AutoScrollController? = nil

    var body: some View {
        if lines.isEmpty {
            Text(placeholder)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let autoScroll {
            SmartScrollingTranscript(lines: lines, controller: autoScroll)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, raw in
                        transcriptRow(raw)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// One styled row per parsed transcript line — raw Markdown source
    /// (`**[00:01:23] Steve:** …`) is never shown; the marker and blank
    /// lines are structural and dropped from display.
    @ViewBuilder
    private func transcriptRow(_ raw: String) -> some View {
        switch TranscriptLine.parse(raw) {
        case .utterance(let ts, let speaker, let text):
            (Text("[\(ts)] ")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
             + Text("\(speaker)  ")
                .font(.callout.weight(.semibold))
             + Text(text)
                .font(.callout))
                .textSelection(.enabled)
        case .header(let title):
            Text(title).font(.headline).padding(.bottom, 2)
        case .plain(let s):
            Text(s).font(.callout).textSelection(.enabled)
        case .marker, .blank:
            EmptyView()
        }
    }
}

/// Smart-auto-scrolling variant used by the live-transcript window (R45).
///
/// Wraps the live-transcript ScrollView and the "Jump to latest" pill. The
/// scroll view itself is `LiveScrollableTranscript` — an NSScrollView-backed
/// `NSViewRepresentable` so we can read the user's scroll position
/// *synchronously, before the new text lays out*. That's the algorithm the
/// user asked for: "before the new line is scheduled to render, is the user
/// at the bottom? If yes, keep them at the bottom."
private struct SmartScrollingTranscript: View {
    let lines: [String]
    let controller: AutoScrollController

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            LiveScrollableTranscript(lines: lines, controller: controller)

            // Pill is overlaid on the scroll area. Animation modifiers are
            // scoped to this Group so they can't cascade into the scroll
            // view's content (which would animate the scroll position).
            Group {
                if !controller.isAtBottom, controller.pendingNewLines > 0 {
                    JumpToLatestPill(count: controller.pendingNewLines) {
                        controller.jumpToLatest()
                    }
                    .padding(12)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .animation(.easeOut(duration: 0.15), value: controller.isAtBottom)
            .animation(.easeOut(duration: 0.15), value: controller.pendingNewLines)
        }
    }
}

/// NSScrollView-backed transcript view. Owns the "before-render" check: each
/// time `updateNSView` runs (called with the new `lines` but *before* the
/// underlying NSTextView's string has been replaced), we sample the
/// `NSScrollView`'s current scroll offset to see if the user was at the
/// bottom. If yes, we set the new text and scroll to the new bottom. If no,
/// we set the new text and leave the scroll position alone, telling the
/// controller to bump `pendingNewLines` so the pill appears.
///
/// Why NSScrollView and not pure SwiftUI: in SwiftUI, `GeometryReader` and
/// `PreferenceKey` fire *after* layout. By the time we'd get the new
/// distance-from-bottom, the new line has already been laid out, and the
/// transient content-growth bump makes the "is user at bottom?" question
/// unanswerable from geometry alone. NSScrollView gives us a synchronous
/// read of the *current* scroll position, sampled at exactly the right
/// moment.
private struct LiveScrollableTranscript: NSViewRepresentable {
    let lines: [String]
    let controller: AutoScrollController

    /// "Essentially at the bottom" — within ~half a line-height (body font is
    /// ~18pt by default, so 8pt is well under a line). Strict on purpose:
    /// the user only wants follow-mode when they are at the bottom.
    private static let bottomThreshold: CGFloat = 8

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.stopObserving()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textStorage?.setAttributedString(Self.attributed(from: lines))

        scrollView.documentView = textView

        // Subscribe to live scroll notifications so we can keep the
        // controller's `isAtBottom` in sync with the user's actual position.
        scrollView.contentView.postsBoundsChangedNotifications = true
        context.coordinator.observe(scrollView: scrollView, threshold: Self.bottomThreshold)
        context.coordinator.lastSeenLineCount = lines.count
        context.coordinator.lastSeenRawText = lines.joined(separator: "\n")

        // Open at the bottom — user's intent is "show me the latest." We
        // need to wait one runloop turn so the text view has finished
        // laying out before we can compute the bottom.
        DispatchQueue.main.async {
            Self.scrollToBottom(in: scrollView, animated: false)
            controller.setIsAtBottom(true)
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        // Change detection compares the RAW joined lines (tracked in the
        // coordinator), not `textView.string` — the rendered text is a
        // styled reformatting that drops marker/blank lines, so it never
        // equals the raw source.
        let newText = lines.joined(separator: "\n")
        let textChanged = context.coordinator.lastSeenRawText != newText

        // ---- The before-render check the user asked for ----
        // Sample NOW, with the OLD text still in place.
        let wasAtBottom = Self.isAtBottom(in: scrollView, threshold: Self.bottomThreshold)
        // -----------------------------------------------------

        if textChanged {
            let oldLineCount = context.coordinator.lastSeenLineCount
            textView.textStorage?.setAttributedString(Self.attributed(from: lines))
            context.coordinator.lastSeenRawText = newText
            // Force layout so the document view's frame reflects the new
            // text before we measure or scroll.
            if let container = textView.textContainer {
                textView.layoutManager?.ensureLayout(for: container)
            }
            context.coordinator.lastSeenLineCount = lines.count

            if wasAtBottom {
                // Keep the user at the bottom.
                Self.scrollToBottom(in: scrollView, animated: false)
                controller.setIsAtBottom(true)
            } else {
                let delta = lines.count - oldLineCount
                controller.notePendingNewLines(delta)
            }
        }

        // Process explicit "Jump to latest" requests from the controller.
        // The controller bumps `jumpToLatestGeneration` each time; we
        // animate a scroll-to-bottom the first time we see a new value.
        if context.coordinator.lastSeenJumpGeneration != controller.jumpToLatestGeneration {
            context.coordinator.lastSeenJumpGeneration = controller.jumpToLatestGeneration
            Self.scrollToBottom(in: scrollView, animated: true)
            controller.setIsAtBottom(true)
        }
    }

    /// Distance from content bottom to viewport bottom (in points) is
    /// `docHeight - (scrollOffset + viewportHeight)`. Within
    /// `threshold` ⇒ at the bottom.
    static func isAtBottom(in scrollView: NSScrollView, threshold: CGFloat) -> Bool {
        guard let documentView = scrollView.documentView else { return true }
        let docHeight = documentView.frame.height
        let viewportHeight = scrollView.contentView.bounds.height
        let offset = scrollView.contentView.bounds.origin.y
        let distance = docHeight - (offset + viewportHeight)
        return distance <= threshold
    }

    /// Styled rendering of the raw transcript lines — same per-line shapes
    /// as the static viewer's `transcriptRow` (timestamp dimmed +
    /// monospaced digits, speaker semibold, text plain; marker and blank
    /// lines dropped).
    private static func attributed(from lines: [String]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.labelColor,
        ]
        let stamp: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(
                ofSize: NSFont.smallSystemFontSize, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let name: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]
        for raw in lines {
            switch TranscriptLine.parse(raw) {
            case .utterance(let ts, let speaker, let text):
                out.append(NSAttributedString(string: "[\(ts)] ", attributes: stamp))
                out.append(NSAttributedString(string: "\(speaker)  ", attributes: name))
                out.append(NSAttributedString(string: text + "\n", attributes: body))
            case .header(let title):
                out.append(NSAttributedString(string: title + "\n", attributes: name))
            case .plain(let s):
                out.append(NSAttributedString(string: s + "\n", attributes: body))
            case .marker, .blank:
                continue
            }
        }
        return out
    }

    static func scrollToBottom(in scrollView: NSScrollView, animated: Bool) {
        guard let documentView = scrollView.documentView else { return }
        let maxY = max(0, documentView.frame.height - scrollView.contentView.bounds.height)
        let target = NSPoint(x: 0, y: maxY)
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                ctx.allowsImplicitAnimation = true
                scrollView.contentView.animator().setBoundsOrigin(target)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        } else {
            scrollView.contentView.setBoundsOrigin(target)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    @MainActor
    final class Coordinator {
        private let controller: AutoScrollController
        private var scrollObserver: NSObjectProtocol?
        var lastSeenLineCount: Int = 0
        var lastSeenJumpGeneration: Int = 0
        /// Raw `lines.joined(separator: "\n")` last rendered — change
        /// detection compares against this, since the styled text in the
        /// view no longer mirrors the raw source.
        var lastSeenRawText: String = ""

        init(controller: AutoScrollController) {
            self.controller = controller
        }

        func observe(scrollView: NSScrollView, threshold: CGFloat) {
            let controller = controller
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak scrollView] _ in
                guard let scrollView else { return }
                MainActor.assumeIsolated {
                    let atBottom = LiveScrollableTranscript.isAtBottom(
                        in: scrollView,
                        threshold: threshold)
                    controller.setIsAtBottom(atBottom)
                }
            }
        }

        /// Called from `dismantleNSView` — runs on the main actor so we can
        /// safely touch `scrollObserver` (Swift 6.2 strict concurrency rules
        /// out doing this from `deinit`, which is nonisolated).
        func stopObserving() {
            if let token = scrollObserver {
                NotificationCenter.default.removeObserver(token)
                scrollObserver = nil
            }
        }
    }
}

/// Floating "Jump to latest" pill — visible only while the user has scrolled
/// away and new lines have accumulated.
private struct JumpToLatestPill: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down")
                Text("\(count) new")
                    .font(.caption.weight(.medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(Color.accentColor)
            )
            .foregroundStyle(.white)
            .shadow(radius: 2, y: 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Jump to latest, \(count) new lines")
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
