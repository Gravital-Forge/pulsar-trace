import AppKit
import PulsarTraceMenuBar
import SwiftUI

/// Click-to-record hotkey field for the Settings pane (PT-R41).
///
/// Focus/keyDown contract (owned by the invisible `KeyCaptureView` AppKit
/// layer; all visuals are SwiftUI reading the same state):
/// - Click focuses the capture view → the field shows "Type shortcut…".
/// - While focused, the first keyDown carrying at least one of ⌃⌥⇧⌘ is
///   captured into `combo` — keyCode plus the same
///   `[.command, .control, .option, .shift]`-masked modifiers
///   `HotkeyController` matches on — and focus is resigned.
/// - Escape cancels: resigns focus, no change.
/// - Delete (⌫) clears `combo` to `nil` and resigns focus.
/// - Unmodified keys are rejected (a bare letter must not become a global
///   hotkey) and fall through to the responder chain.
struct HotkeyRecorderField: View {
    @Binding var combo: KeyCombo?
    /// Flipped by the capture view's first-responder transitions.
    @State private var isRecording = false

    var body: some View {
        KeyCaptureView(combo: $combo, isRecording: $isRecording)
            .frame(width: 170, height: 22)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        isRecording
                            ? Color.accentColor
                            : Color(nsColor: .separatorColor)))
            .overlay(
                Text(label)
                    .foregroundStyle(
                        combo == nil || isRecording ? .secondary : .primary)
                    // Clicks must reach the capture NSView underneath.
                    .allowsHitTesting(false))
    }

    private var label: String {
        if isRecording { return "Type shortcut…" }
        guard let combo else { return "Click to record shortcut" }
        return KeyComboFormatter.displayString(for: combo)
    }
}

/// The AppKit half: an empty focusable NSView that turns the next qualifying
/// keypress into a `KeyCombo`. Closures are (re)assigned on every update so
/// they always capture fresh bindings.
private struct KeyCaptureView: NSViewRepresentable {
    @Binding var combo: KeyCombo?
    @Binding var isRecording: Bool

    func makeNSView(context: Context) -> KeyCaptureNSView {
        let view = KeyCaptureNSView()
        apply(to: view)
        return view
    }

    func updateNSView(_ view: KeyCaptureNSView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: KeyCaptureNSView) {
        view.onFocusChange = { isRecording = $0 }
        view.onCapture = { combo = $0 }
    }
}

private final class KeyCaptureNSView: NSView {
    var onFocusChange: ((Bool) -> Void)?
    /// Called with the captured combo, or `nil` for "clear" (Delete).
    var onCapture: ((KeyCombo?) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func becomeFirstResponder() -> Bool {
        onFocusChange?(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        onFocusChange?(false)
        return true
    }

    override func keyDown(with event: NSEvent) {
        if !handle(event) { super.keyDown(with: event) }
    }

    /// ⌘-modified presses are routed as key equivalents *before* `keyDown`
    /// — intercept them while focused, or recording ⌘R would fire a menu
    /// item instead of being captured.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown else {
            return super.performKeyEquivalent(with: event)
        }
        return handle(event)
    }

    /// Returns `true` when the event was consumed (captured, cleared, or
    /// cancelled); `false` lets it continue down the responder chain.
    private func handle(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53:  // Escape — cancel recording, keep the existing combo.
            window?.makeFirstResponder(nil)
            return true
        case 51:  // Delete (⌫) — clear the stored combo.
            onCapture?(nil)
            window?.makeFirstResponder(nil)
            return true
        default:
            let relevant: NSEvent.ModifierFlags =
                [.command, .control, .option, .shift]
            let modifiers = event.modifierFlags.intersection(relevant)
            // Require at least one of ⌘/⌃/⌥ — shift alone is typing, not a
            // shortcut: a ⇧R hotkey would fire on every capital R typed
            // anywhere. Matches macOS recorder conventions.
            let nonShift: NSEvent.ModifierFlags = [.command, .control, .option]
            guard !modifiers.intersection(nonShift).isEmpty else { return false }
            onCapture?(KeyCombo(
                keyCode: event.keyCode, modifiers: modifiers.rawValue))
            window?.makeFirstResponder(nil)
            return true
        }
    }
}
