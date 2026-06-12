import AppKit
import PulsarTraceMenuBar
import SwiftUI

/// The app's single read-only transcript renderer (§5).
///
/// One NSTextView-backed implementation serves both modes — the detached
/// live-transcript window (lines tailed from `live.md`) and the recorded
/// transcript viewer (lines read once from `final.md`/`live.md`). There is no
/// longer a separate SwiftUI `LazyVStack` path: a single NSTextView gives
/// cross-line text selection (broken in the old per-row path) and
/// find-in-transcript (⌘F via the system find bar).
///
/// Mode is selected by `autoScroll`: when an `AutoScrollController` is passed,
/// the view runs the live smart-auto-scroll behavior (R45) and opens at the
/// bottom; when it is `nil`, the transcript is static and opens at the top
/// with no follow-mode and no jump pill.
struct TranscriptView: View {
    /// The transcript lines, in file order.
    let lines: [String]
    /// Shown when `lines` is empty.
    var placeholder: String = "No transcript yet."
    /// Opt-in smart auto-scroll (live mode). `nil` = static transcript:
    /// opens at the top, no follow-mode, no jump pill.
    var autoScroll: AutoScrollController? = nil
    /// Find-in-transcript hook (⌘F / toolbar Find) — optional.
    var findActivator: TranscriptFindActivator? = nil

    var body: some View {
        if lines.isEmpty {
            Text(placeholder)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let autoScroll {
            ZStack(alignment: .bottomTrailing) {
                TranscriptTextView(
                    lines: lines, controller: autoScroll,
                    findActivator: findActivator)
                Group {
                    if !autoScroll.isAtBottom, autoScroll.pendingNewLines > 0 {
                        JumpToLatestPill(count: autoScroll.pendingNewLines) {
                            autoScroll.jumpToLatest()
                        }
                        .padding(12)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .animation(.easeOut(duration: 0.15), value: autoScroll.isAtBottom)
                .animation(.easeOut(duration: 0.15), value: autoScroll.pendingNewLines)
            }
        } else {
            TranscriptTextView(
                lines: lines, controller: nil, findActivator: findActivator)
        }
    }
}

/// NSScrollView-backed transcript view — the single renderer for both live
/// and static modes (§5).
///
/// In live mode (`controller != nil`) it owns the "before-render" check: each
/// time `updateNSView` runs (called with the new `lines` but *before* the
/// underlying NSTextView's string has been replaced), we sample the
/// `NSScrollView`'s current scroll offset to see if the user was at the
/// bottom. If yes, we set the new text and scroll to the new bottom. If no,
/// we set the new text and leave the scroll position alone, telling the
/// controller to bump `pendingNewLines` so the pill appears. In static mode
/// (`controller == nil`) the view simply renders the lines and opens at the
/// top — no scroll observation, no follow-mode.
///
/// Why NSScrollView and not pure SwiftUI: in SwiftUI, `GeometryReader` and
/// `PreferenceKey` fire *after* layout. By the time we'd get the new
/// distance-from-bottom, the new line has already been laid out, and the
/// transient content-growth bump makes the "is user at bottom?" question
/// unanswerable from geometry alone. NSScrollView gives us a synchronous
/// read of the *current* scroll position, sampled at exactly the right
/// moment.
@MainActor
private struct TranscriptTextView: NSViewRepresentable {
    let lines: [String]
    let controller: AutoScrollController?
    let findActivator: TranscriptFindActivator?

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

        // TextKit 1 explicitly: every measurement here (`isAtBottom`,
        // `scrollToBottom`, `ensureLayout`) assumes synchronous full layout.
        // A bare NSTextView() would start on TextKit 2 and silently downgrade
        // on the first `layoutManager` access — pin the engine instead.
        let textView = NSTextView(usingTextLayoutManager: false)
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
        // Find-in-transcript (⌘F): the system find bar, incremental search on.
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textStorage?.setAttributedString(Self.attributed(from: lines))

        scrollView.documentView = textView

        // Wire the find activator to this text view so the toolbar Find button
        // / ⌘F can drive the find bar (the accessory app has no visible menu
        // bar, so the standard responder-chain route is replaced — §5).
        findActivator?.textView = textView

        context.coordinator.lastSeenLineCount = lines.count
        context.coordinator.lastSeenRawText = lines.joined(separator: "\n")

        // Live mode only: subscribe to scroll notifications so the
        // controller's `isAtBottom` tracks the user's position, and open at
        // the bottom (user's intent is "show me the latest"). Static mode
        // opens at the top — NSScrollView's natural origin — so there is
        // nothing to do. The mode is fixed at make time on purpose:
        // `TranscriptView.body`'s branches guarantee a fresh NSView whenever
        // `autoScroll` flips nil↔non-nil.
        if let controller {
            scrollView.contentView.postsBoundsChangedNotifications = true
            context.coordinator.observe(scrollView: scrollView, threshold: Self.bottomThreshold)

            // Wait one runloop turn so the text view has finished laying out
            // before we compute the bottom.
            DispatchQueue.main.async {
                Self.scrollToBottom(in: scrollView, animated: false)
                controller.setIsAtBottom(true)
            }
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        // SwiftUI may rebuild this representable's `rootView` (and so re-run
        // `updateNSView`) while reusing the same NSView; re-register the find
        // activator so it always points at the live text view.
        findActivator?.textView = textView

        // Change detection compares the RAW joined lines (tracked in the
        // coordinator), not `textView.string` — the rendered text is a
        // styled reformatting that drops marker/blank lines, so it never
        // equals the raw source.
        let oldText = context.coordinator.lastSeenRawText
        let newText = lines.joined(separator: "\n")
        let textChanged = oldText != newText

        // ---- The before-render check (live mode only) ----
        // Sample NOW, with the OLD text still in place.
        let wasAtBottom = controller != nil
            && Self.isAtBottom(in: scrollView, threshold: Self.bottomThreshold)
        // ---------------------------------------------------

        if textChanged {
            let oldCount = context.coordinator.lastSeenLineCount
            // Suffix-append fast path (§5): live updates append
            // `lines[oldCount...]` instead of rebuilding the whole attributed
            // string per poll tick. The boundary must be a clean line break —
            // a mutated tail line falls back to the full rebuild, as does a
            // shrink (truncation/overwrite).
            if lines.count > oldCount, oldCount > 0,
               newText.count > oldText.count,
               newText.hasPrefix(oldText),
               newText[newText.index(newText.startIndex, offsetBy: oldText.count)] == "\n" {
                textView.textStorage?.append(
                    Self.attributed(from: Array(lines[oldCount...])))
            } else {
                textView.textStorage?.setAttributedString(Self.attributed(from: lines))
            }
            context.coordinator.lastSeenRawText = newText
            // Force layout so the document view's frame reflects the new
            // text before we measure or scroll.
            if let container = textView.textContainer {
                textView.layoutManager?.ensureLayout(for: container)
            }
            context.coordinator.lastSeenLineCount = lines.count

            if let controller {
                if wasAtBottom {
                    // Keep the user at the bottom.
                    Self.scrollToBottom(in: scrollView, animated: false)
                    controller.setIsAtBottom(true)
                } else {
                    controller.notePendingNewLines(lines.count - oldCount)
                }
            }
        }

        // Process explicit "Jump to latest" requests from the controller
        // (live mode only). The controller bumps `jumpToLatestGeneration` each
        // time; we animate a scroll-to-bottom the first time we see a new
        // value.
        if let controller,
           context.coordinator.lastSeenJumpGeneration != controller.jumpToLatestGeneration {
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

    /// Styled rendering of the raw transcript lines (timestamp dimmed +
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
        private let controller: AutoScrollController?
        private var scrollObserver: NSObjectProtocol?
        var lastSeenLineCount: Int = 0
        var lastSeenJumpGeneration: Int = 0
        /// Raw `lines.joined(separator: "\n")` last rendered — change
        /// detection compares against this, since the styled text in the
        /// view no longer mirrors the raw source.
        var lastSeenRawText: String = ""

        init(controller: AutoScrollController?) {
            self.controller = controller
        }

        func observe(scrollView: NSScrollView, threshold: CGFloat) {
            guard let controller else { return }
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak scrollView] _ in
                guard let scrollView else { return }
                MainActor.assumeIsolated {
                    let atBottom = TranscriptTextView.isAtBottom(
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

/// Bridges the SwiftUI Find affordance (toolbar button / ⌘F) to the
/// NSTextView's NSTextFinder find bar. The accessory app has no visible menu
/// bar, so the standard ⌘F responder-chain route is wired explicitly (§5
/// risk flag).
@MainActor
final class TranscriptFindActivator {
    weak var textView: NSTextView?

    func showFind() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        textView.performTextFinderAction(item)
    }
}

/// Copy a transcript's lines to the general pasteboard as rendered plain text
/// — "Copy copies what you see" (§5). The styled renderer drops marker/blank
/// lines and reformats utterances, so we copy that rendering (the same text
/// selection + ⌘C from the NSTextView yields), not the raw Markdown source;
/// the raw file remains one Reveal-in-Finder away.
@MainActor
func copyTranscriptToPasteboard(_ lines: [String]) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(TranscriptPlainText.rendered(from: lines), forType: .string)
}
