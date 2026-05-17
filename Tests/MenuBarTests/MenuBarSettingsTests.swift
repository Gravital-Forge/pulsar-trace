import Testing
import Foundation
@testable import PulsarTraceMenuBar

/// Epic 8 — `MenuBarSettings` round-trips every property through an injected
/// `UserDefaults` suite, so a relaunch restores the user's choices (R42/R43).
@Suite("MenuBarSettings (Epic 8)")
@MainActor
struct MenuBarSettingsTests {

    /// A throwaway `UserDefaults` suite; the caller removes it.
    private func tempSuite() -> (UserDefaults, String) {
        let name = "pt-menubar-test-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test("every property round-trips through the backing UserDefaults suite")
    func roundTrip() throws {
        let (defaults, suiteName) = tempSuite()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let bookmark = Data([0x01, 0x02, 0x03])
        let previous = [Data([0xAA]), Data([0xBB])]

        do {
            let settings = MenuBarSettings(defaults: defaults)
            settings.selectedMicDeviceID = "BuiltInMic-7F3A"
            settings.liveModelName = "base"
            settings.refineModelName = "large-v3"
            settings.outputFolderBookmark = bookmark
            settings.systemAudioEnabled = false
            settings.globalHotkey = KeyCombo(keyCode: 15, modifiers: 1_048_576)
            settings.previousFolderBookmarks = previous
        }

        // A fresh instance reading the same suite sees the persisted values.
        let reloaded = MenuBarSettings(defaults: defaults)
        #expect(reloaded.selectedMicDeviceID == "BuiltInMic-7F3A")
        #expect(reloaded.liveModelName == "base")
        #expect(reloaded.refineModelName == "large-v3")
        #expect(reloaded.outputFolderBookmark == bookmark)
        #expect(reloaded.systemAudioEnabled == false)
        #expect(reloaded.globalHotkey == KeyCombo(keyCode: 15, modifiers: 1_048_576))
        #expect(reloaded.previousFolderBookmarks == previous)
    }

    @Test("a fresh suite yields the documented defaults")
    func defaults() {
        let (defaults, suiteName) = tempSuite()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = MenuBarSettings(defaults: defaults)
        #expect(settings.liveModelName == MenuBarSettings.defaultLiveModelName)
        #expect(settings.refineModelName == MenuBarSettings.defaultRefineModelName)
        #expect(settings.systemAudioEnabled == true)
        #expect(settings.selectedMicDeviceID == nil)
        #expect(settings.outputFolderBookmark == nil)
        #expect(settings.globalHotkey == nil)
        #expect(settings.previousFolderBookmarks.isEmpty)
    }

    @Test("a legacy `modelName` key migrates into `liveModelName` (D29)")
    func legacyModelNameMigrates() {
        let (defaults, suiteName) = tempSuite()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Simulate a pre-D29 store: only the legacy single `modelName` key.
        defaults.set("large-v3", forKey: "modelName")

        let settings = MenuBarSettings(defaults: defaults)
        // The legacy value seeds the live model; refine falls back to default.
        #expect(settings.liveModelName == "large-v3")
        #expect(settings.refineModelName == MenuBarSettings.defaultRefineModelName)
    }

    @Test("the new keys win over a stale legacy `modelName` key")
    func newKeysWinOverLegacy() {
        let (defaults, suiteName) = tempSuite()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("large-v3", forKey: "modelName")    // legacy
        defaults.set("base", forKey: "liveModelName")     // new
        defaults.set("large-v3", forKey: "refineModelName")

        let settings = MenuBarSettings(defaults: defaults)
        #expect(settings.liveModelName == "base")
        #expect(settings.refineModelName == "large-v3")
    }

    @Test("clearing the hotkey removes it from the store")
    func hotkeyClears() {
        let (defaults, suiteName) = tempSuite()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        do {
            let settings = MenuBarSettings(defaults: defaults)
            settings.globalHotkey = KeyCombo(keyCode: 9, modifiers: 256)
            settings.globalHotkey = nil
        }
        #expect(MenuBarSettings(defaults: defaults).globalHotkey == nil)
    }

    @Test("a security-scoped bookmark of a real folder resolves back to it")
    @MainActor
    func bookmarkRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-bm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // `resolveBookmark` is private; exercise it through the public
        // `outputFolderURL` derived property (its only caller).
        let defaults = UserDefaults(suiteName: "pt-bm-\(UUID().uuidString)")!
        let settings = MenuBarSettings(defaults: defaults)
        settings.outputFolderBookmark = try MenuBarSettings.makeBookmark(for: dir)
        #expect(settings.outputFolderURL?.standardizedFileURL
            == dir.standardizedFileURL)
    }
}
