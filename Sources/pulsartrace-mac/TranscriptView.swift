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

/// Smart-auto-scrolling variant used by the live-transcript window.
///
/// Layout:
/// - Outer `GeometryReader` → viewport height.
/// - `ScrollViewReader` → programmatic scroll to the bottom anchor.
/// - `ScrollView` with a named coordinate space → inner `GeometryReader`
///   measures content `maxY` in that space.
/// - A 1pt-tall `Color.clear` anchor at the end of the content is the
///   `scrollTo` target.
/// - Distance from bottom = `inner.maxY - outerHeight`; this is fed to
///   the controller on every preference change.
/// - On `lines.count` growth the controller decides whether to scroll.
/// - When `controller.shouldFollow == false && controller.pendingNewLines > 0`,
///   a "Jump to latest ↓ N" pill is shown bottom-trailing in the scroll area.
private struct SmartScrollingTranscript: View {
    let lines: [String]
    let controller: AutoScrollController

    /// Tracks the line count we already reacted to so we can compute deltas.
    @State private var lastSeenLineCount: Int = 0

    private static let bottomAnchorID = "pulsartrace.transcript.bottom"
    private static let coordSpace = "pulsartrace.transcript.scroll"

    var body: some View {
        GeometryReader { outerGeo in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(lines.joined(separator: "\n"))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                        Color.clear
                            .frame(height: 1)
                            .id(Self.bottomAnchorID)
                    }
                    .background(
                        GeometryReader { innerGeo in
                            let maxY = innerGeo
                                .frame(in: .named(Self.coordSpace))
                                .maxY
                            Color.clear.preference(
                                key: DistanceFromBottomKey.self,
                                value: maxY - outerGeo.size.height
                            )
                        }
                    )
                }
                .coordinateSpace(name: Self.coordSpace)
                .onPreferenceChange(DistanceFromBottomKey.self) { distance in
                    controller.updateDistanceFromBottom(distance)
                }
                .onChange(of: lines.count) { _, newCount in
                    let delta = newCount - lastSeenLineCount
                    lastSeenLineCount = newCount
                    if controller.linesDidGrow(by: delta) {
                        // Snap, don't animate: each new line is a small move
                        // and an animation here fights the transient distance
                        // bump (animations cascade through SwiftUI transactions
                        // and can produce a visible scroll snap-back).
                        proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                    }
                }
                .onAppear {
                    lastSeenLineCount = lines.count
                    if lines.count > 0 {
                        // The user's intent on opening the window is "show me
                        // the latest" — reset to follow-mode in case an early
                        // preference-update flipped shouldFollow before this
                        // ran, then jump to bottom without animation.
                        controller.jumpToLatest()
                        proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    // Animations are scoped to this overlay so they cannot
                    // cascade into the ScrollView's content (where they would
                    // animate the scroll position itself).
                    Group {
                        if !controller.shouldFollow, controller.pendingNewLines > 0 {
                            JumpToLatestPill(count: controller.pendingNewLines) {
                                controller.jumpToLatest()
                                withAnimation(.easeOut(duration: 0.15)) {
                                    proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                                }
                            }
                            .padding(12)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                    }
                    .animation(.easeOut(duration: 0.15), value: controller.shouldFollow)
                    .animation(.easeOut(duration: 0.15), value: controller.pendingNewLines)
                }
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

/// SwiftUI `PreferenceKey` carrying distance from content bottom to viewport
/// bottom (in points). Positive = content extends below visible area; zero or
/// negative = content fits or is fully scrolled.
private struct DistanceFromBottomKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
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
