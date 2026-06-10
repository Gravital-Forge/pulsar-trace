import Foundation
import AppKit
import Testing
@testable import PulsarTraceMenuBar

@Suite("KeyComboFormatter")
struct KeyComboFormatterTests {
    @Test("⇧⌘R renders with canonical modifier order")
    func cmdShiftR() {
        let combo = KeyCombo(
            keyCode: 15,  // kVK_ANSI_R
            modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue)
        #expect(KeyComboFormatter.displayString(for: combo) == "⇧⌘R")
    }

    @Test("all four modifiers render in ⌃⌥⇧⌘ order")
    func allModifiers() {
        let combo = KeyCombo(
            keyCode: 15,
            modifiers: NSEvent.ModifierFlags([.command, .shift, .option, .control]).rawValue)
        #expect(KeyComboFormatter.displayString(for: combo) == "⌃⌥⇧⌘R")
    }

    @Test("an unmapped key code falls back to 'key N'")
    func unmapped() {
        let combo = KeyCombo(keyCode: 999, modifiers: 0)
        #expect(KeyComboFormatter.displayString(for: combo) == "key 999")
    }

    @Test("named special keys render their glyphs")
    func specials() {
        #expect(KeyComboFormatter.displayString(for: KeyCombo(keyCode: 36, modifiers: 0)) == "↩")   // Return
        #expect(KeyComboFormatter.displayString(for: KeyCombo(keyCode: 49, modifiers: 0)) == "Space")
        #expect(KeyComboFormatter.displayString(for: KeyCombo(keyCode: 53, modifiers: 0)) == "⎋")   // Escape
    }
}
