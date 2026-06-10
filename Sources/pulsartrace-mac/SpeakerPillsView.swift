import PulsarTraceMenuBar
import SwiftUI

/// Wrapping pill chips listing the speakers in a refined recording (R31).
///
/// Replaces the older "N speakers" count subtitle in `RecordingsListView` with
/// the richer information that is already in `metadata.json`: each speaker as
/// a capsule chip tinted by kind (mic "You" / `Unknown #N` placeholder /
/// named). Pills wrap across rows when there are many, so a long meeting with
/// six attendees doesn't truncate or stretch the row to one line.
///
/// We use a custom `Layout` because SwiftUI ships no built-in flow/wrap
/// container even on macOS 14: `HStack` does not wrap, and `LazyVGrid`
/// requires a fixed column count which would either truncate names or leave
/// gaps. The implementation is intentionally tiny — `sizeThatFits` and
/// `placeSubviews` share one row-walking helper so the two passes can never
/// disagree about row count if the parent grants narrower bounds than it
/// proposed.
///
/// Renders nothing for an empty array (an unrefined recording, or a refined
/// one whose metadata listed no speakers).
struct SpeakerPillsView: View {

    let speakers: [RecordingSpeaker]

    var body: some View {
        let visible = dedupedSpeakers
        if visible.isEmpty {
            EmptyView()
        } else {
            PillFlowLayout(horizontalSpacing: 4, verticalSpacing: 4) {
                // Enumerate so two un-reconciled speakers that happen to
                // share a label (rare but possible in hand-edited
                // metadata) get distinct `ForEach` ids — relying on
                // `RecordingSpeaker.id` alone would collide and trigger a
                // SwiftUI runtime warning.
                ForEach(Array(visible.enumerated()), id: \.offset) { _, speaker in
                    pill(for: speaker)
                }
            }
        }
    }

    /// Collapse rows that share `(label, isMicrophone)`. A pre-fix merge
    /// (before `FinalMarkdownRewriter` learned to drop the merged-away
    /// `speakerId`) left some recordings with two `metadata.json` rows
    /// that both relabelled to the primary's name — rendering them
    /// directly would show one person as two pills. First occurrence
    /// wins; the rewriter self-heals these on the next rewrite.
    private var dedupedSpeakers: [RecordingSpeaker] {
        var seen: Set<String> = []
        return speakers.filter { speaker in
            let key = "\(speaker.label)\u{1F}\(speaker.isMicrophone)"
            return seen.insert(key).inserted
        }
    }

    /// One capsule chip — caption-sized, tinted per speaker kind, with a
    /// hard upper width so a pathologically long or multi-line label
    /// can't stretch the recordings-list row off-screen.
    @ViewBuilder
    private func pill(for speaker: RecordingSpeaker) -> some View {
        let style = pillStyle(for: speaker)
        Text(speaker.label)
            .font(.caption)
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundStyle(style.foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(style.background, in: Capsule())
            .frame(maxWidth: 160, alignment: .leading)
            // The kind is otherwise encoded by colour only — name it for
            // VoiceOver alongside the label. `.combine` folds the inner Text
            // into this element so VoiceOver reads one label, not a doubled
            // "Alice, Alice, microphone".
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(speaker.label), \(kindDescription(for: speaker))")
    }

    /// Spoken counterpart of `pillStyle(for:)` — mirrors the same predicate
    /// order (mic wins over the unknown-placeholder check).
    private func kindDescription(for speaker: RecordingSpeaker) -> String {
        if speaker.isMicrophone { return "microphone" }
        if speaker.isUnknownPlaceholder { return "unnamed speaker" }
        return "known speaker"
    }

    /// Pick the chip tint based on speaker kind. Order matters: the mic
    /// stream takes priority — `isUnknownPlaceholder` is computed off
    /// `label` and could in principle be true for a "You"-labelled speaker,
    /// though in practice it isn't.
    private func pillStyle(for speaker: RecordingSpeaker) -> PillStyle {
        if speaker.isMicrophone {
            return PillStyle(
                background: Color.blue.opacity(0.15),
                foreground: .blue)
        }
        if speaker.isUnknownPlaceholder {
            return PillStyle(
                background: Color.orange.opacity(0.15),
                foreground: .orange)
        }
        return PillStyle(
            background: Color.secondary.opacity(0.15),
            foreground: .primary)
    }

    private struct PillStyle {
        let background: Color
        let foreground: Color
    }
}

/// A minimal flow layout — children arranged left-to-right, wrapping to a new
/// row when the next child would overflow the available width.
///
/// `sizeThatFits` and `placeSubviews` share `layoutRows` so the two passes use
/// identical wrap math. `placeSubviews` walks against `bounds.width` (the
/// width the parent actually granted) rather than `proposal.width` — a parent
/// can grant a narrower box than it proposed, and matching against bounds
/// keeps the placed rows aligned with the reported height.
///
/// No `Layout.Cache` — the children list is short (speakers per recording,
/// typically <10) so the recomputation cost is negligible and avoids
/// cache-invalidation footguns.
private struct PillFlowLayout: Layout {

    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        return Self.layoutRows(
            subviews: subviews,
            maxWidth: maxWidth,
            hSpacing: horizontalSpacing,
            vSpacing: verticalSpacing).size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        // Wrap against the granted width — sizeThatFits used `proposal.width`,
        // but a parent can clamp us narrower; using `bounds.width` here
        // re-runs the same math on the actual box so rows don't drift.
        let plan = Self.layoutRows(
            subviews: subviews,
            maxWidth: bounds.width,
            hSpacing: horizontalSpacing,
            vSpacing: verticalSpacing)
        for (index, frame) in plan.frames.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX,
                            y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(
                    width: frame.width, height: frame.height))
        }
    }

    /// Walk children into rows and return both the total size and the per-
    /// child frames (in the layout's own coordinate space). Used by both
    /// `sizeThatFits` and `placeSubviews` so the wrap math is identical —
    /// previously the two methods drifted on row count when bounds.width
    /// differed from proposal.width.
    ///
    /// A single child wider than `maxWidth` is clamped to `maxWidth` rather
    /// than overflowing silently — only matters for `lineLimit(1)` chips
    /// (they'll truncate via the inner `Text` modifier) or for a finite
    /// `maxWidth` of zero (an intrinsic-size probe).
    private static func layoutRows(
        subviews: Subviews,
        maxWidth: CGFloat,
        hSpacing: CGFloat,
        vSpacing: CGFloat
    ) -> (size: CGSize, frames: [CGRect]) {
        var frames: [CGRect] = []
        frames.reserveCapacity(subviews.count)
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let raw = subview.sizeThatFits(.unspecified)
            let clampedWidth = maxWidth.isFinite
                ? min(raw.width, maxWidth)
                : raw.width
            let projected = x == 0 ? clampedWidth : x + hSpacing + clampedWidth
            if projected > maxWidth && x > 0 {
                totalWidth = max(totalWidth, x)
                y += rowHeight + vSpacing
                x = 0
                rowHeight = 0
            }
            let offsetX = x == 0 ? 0 : x + hSpacing
            frames.append(CGRect(
                x: offsetX, y: y, width: clampedWidth, height: raw.height))
            x = offsetX + clampedWidth
            rowHeight = max(rowHeight, raw.height)
        }
        totalWidth = max(totalWidth, x)
        let totalHeight = y + rowHeight
        return (CGSize(width: totalWidth, height: totalHeight), frames)
    }
}
