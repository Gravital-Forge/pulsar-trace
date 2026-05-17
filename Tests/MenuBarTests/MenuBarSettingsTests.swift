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

        let folderPath = "/Users/test/PulsarTrace Recordings"
        let previous = ["/Users/test/Old One", "/Users/test/Old Two"]

        do {
            let settings = MenuBarSettings(defaults: defaults)
            settings.selectedMicDeviceID = "BuiltInMic-7F3A"
            settings.liveModelName = "base"
            settings.refineModelName = "large-v3"
            settings.outputFolderPath = folderPath
            settings.systemAudioEnabled = false
            settings.globalHotkey = KeyCombo(keyCode: 15, modifiers: 1_048_576)
            settings.previousFolderPaths = previous
        }

        // A fresh instance reading the same suite sees the persisted values.
        let reloaded = MenuBarSettings(defaults: defaults)
        #expect(reloaded.selectedMicDeviceID == "BuiltInMic-7F3A")
        #expect(reloaded.liveModelName == "base")
        #expect(reloaded.refineModelName == "large-v3")
        #expect(reloaded.outputFolderPath == folderPath)
        #expect(reloaded.outputFolderURL?.path == folderPath)
        #expect(reloaded.systemAudioEnabled == false)
        #expect(reloaded.globalHotkey == KeyCombo(keyCode: 15, modifiers: 1_048_576))
        #expect(reloaded.previousFolderPaths == previous)
        #expect(reloaded.previousFolderURLs.map(\.path) == previous)
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
        #expect(settings.outputFolderPath == nil)
        #expect(settings.outputFolderURL == nil)
        #expect(settings.globalHotkey == nil)
        #expect(settings.previousFolderPaths.isEmpty)
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

    @Test("a stored output-folder path round-trips into outputFolderURL")
    @MainActor
    func outputFolderPathRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-of-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let defaults = UserDefaults(suiteName: "pt-of-\(UUID().uuidString)")!
        let settings = MenuBarSettings(defaults: defaults)
        settings.outputFolderPath = dir.path
        #expect(settings.outputFolderURL?.standardizedFileURL
            == dir.standardizedFileURL)
    }

    @Test("a legacy security-scoped bookmark migrates to a plain path (D30)")
    @MainActor
    func legacyBookmarkMigratesToPath() throws {
        let (defaults, suiteName) = tempSuite()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Two real folders an old install would have bookmarked.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-mig-\(UUID().uuidString)", isDirectory: true)
        let prevDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-mig-prev-\(UUID().uuidString)", isDirectory: true)
        for d in [dir, prevDir] {
            try FileManager.default.createDirectory(
                at: d, withIntermediateDirectories: true)
        }
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: prevDir)
        }

        // Simulate a pre-D30 store: only the legacy bookmark keys are present.
        let bookmark = try dir.bookmarkData()
        let prevBookmark = try prevDir.bookmarkData()
        defaults.set(bookmark, forKey: "outputFolderBookmark")
        defaults.set([prevBookmark], forKey: "previousFolderBookmarks")

        // Loading migrates each legacy bookmark to a plain path.
        let settings = MenuBarSettings(defaults: defaults)
        #expect(settings.outputFolderURL?.standardizedFileURL
            == dir.standardizedFileURL)
        #expect(settings.previousFolderURLs.map(\.standardizedFileURL)
            == [prevDir.standardizedFileURL])

        // The legacy keys are dropped so they cannot resurface.
        #expect(defaults.object(forKey: "outputFolderBookmark") == nil)
        #expect(defaults.object(forKey: "previousFolderBookmarks") == nil)
        #expect(defaults.string(forKey: "outputFolderPath").map {
            URL(fileURLWithPath: $0).standardizedFileURL
        } == dir.standardizedFileURL)
    }

    @Test("the new path key wins over a stale legacy bookmark (D30)")
    @MainActor
    func newPathKeyWinsOverLegacyBookmark() throws {
        let (defaults, suiteName) = tempSuite()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(Data([0xDE, 0xAD]), forKey: "outputFolderBookmark") // junk
        defaults.set("/Users/test/Chosen", forKey: "outputFolderPath")

        let settings = MenuBarSettings(defaults: defaults)
        #expect(settings.outputFolderPath == "/Users/test/Chosen")
        #expect(defaults.object(forKey: "outputFolderBookmark") == nil)
    }
}
