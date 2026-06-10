import AppKit
import Foundation

/// Renders a `KeyCombo` as the canonical macOS shortcut string, e.g. `⇧⌘R`.
///
/// Modifier glyphs appear in the canonical macOS order — Control ⌃,
/// Option ⌥, Shift ⇧, Command ⌘ — followed by the key's name.
///
/// On the AppKit import: this library's no-AppKit posture concerns event
/// monitors and UI (those live in the app target, see `HotkeyController`);
/// this type uses `NSEvent.ModifierFlags` purely as value-level flag
/// constants to decode `KeyCombo.modifiers`, which keeps it fully testable
/// off the main thread and is an accepted exception.
///
/// Key names come from a static table of the well-known macOS virtual
/// keycodes (verified against Carbon's `HIToolbox/Events.h` `kVK_*`
/// constants) rather than `UCKeyTranslate` — deliberate pragmatism: the
/// table covers letters, digits, F-keys, arrows, and the common specials,
/// and assumes an ANSI layout. Anything unmapped falls back to
/// `"key <code>"`, which is also what the Settings pane displayed before
/// this formatter existed.
public enum KeyComboFormatter {

    /// The display string for `combo`, e.g. `⌃⌥⇧⌘R`, `⇧⌘Space`, `key 999`.
    public static func displayString(for combo: KeyCombo) -> String {
        let flags = NSEvent.ModifierFlags(rawValue: combo.modifiers)
        var out = ""
        if flags.contains(.control) { out += "⌃" }
        if flags.contains(.option) { out += "⌥" }
        if flags.contains(.shift) { out += "⇧" }
        if flags.contains(.command) { out += "⌘" }
        out += keyNames[combo.keyCode] ?? "key \(combo.keyCode)"
        return out
    }

    /// Virtual keycode → display name, per `kVK_*` in HIToolbox `Events.h`
    /// (ANSI layout).
    private static let keyNames: [UInt16: String] = [
        // Letters (kVK_ANSI_A … kVK_ANSI_Z).
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H",
        34: "I", 38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O",
        35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V",
        13: "W", 7: "X", 16: "Y", 6: "Z",
        // Digits (kVK_ANSI_0 … kVK_ANSI_9).
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6",
        26: "7", 28: "8", 25: "9",
        // Specials.
        49: "Space", 36: "↩", 48: "⇥", 53: "⎋", 51: "⌫",
        // Arrows.
        123: "←", 124: "→", 125: "↓", 126: "↑",
        // Function keys (kVK_F1 … kVK_F12).
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]
}
