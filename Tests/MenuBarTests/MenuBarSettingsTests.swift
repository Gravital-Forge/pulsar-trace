import Testing
import Foundation
@testable import PulsarTraceMenuBar

/// `MenuBarSettings` round-trips every property through an injected
/// `UserDefaults` suite, so a relaunch restores the user's choices (PT-R42/PT-R43).
@Suite("MenuBarSettings")
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
            settings.refineModelName = "large-v3-whisperkit"
            settings.outputFolderPath = folderPath
            settings.systemAudioEnabled = false
            settings.globalHotkey = KeyCombo(keyCode: 15, modifiers: 1_048_576)
            settings.previousFolderPaths = previous
        }

        // A fresh instance reading the same suite sees the persisted values.
        let reloaded = MenuBarSettings(defaults: defaults)
        #expect(reloaded.selectedMicDeviceID == "BuiltInMic-7F3A")
        #expect(reloaded.refineModelName == "large-v3-whisperkit")
        #expect(reloaded.outputFolderPath == folderPath)
        #expect(reloaded.outputFolderURL?.path == folderPath)
        #expect(reloaded.systemAudioEnabled == false)
        #expect(reloaded.globalHotkey == KeyCombo(keyCode: 15, modifiers: 1_048_576))
        #expect(reloaded.previousFolderPaths == previous)
        #expect(reloaded.previousFolderURLs.map(\.path) == previous)
    }

    @Test("MCP server toggle and port default off / 8276 and round-trip (PT-P6-R1)")
    func mcpSettingsRoundTrip() {
        let (defaults, suiteName) = tempSuite()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let fresh = MenuBarSettings(defaults: defaults)
        #expect(fresh.mcpServerEnabled == false)
        #expect(fresh.mcpServerPort == 8276)

        fresh.mcpServerEnabled = true
        fresh.mcpServerPort = 9001

        let reloaded = MenuBarSettings(defaults: defaults)
        #expect(reloaded.mcpServerEnabled == true)
        #expect(reloaded.mcpServerPort == 9001)
    }

    @Test("diarizeMicEnabled defaults false and persists (PT-P8-R12)")
    func diarizeMicPersists() {
        let (defaults, suiteName) = tempSuite()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = MenuBarSettings(defaults: defaults)
        #expect(settings.diarizeMicEnabled == false)
        settings.diarizeMicEnabled = true
        let reloaded = MenuBarSettings(defaults: defaults)
        #expect(reloaded.diarizeMicEnabled == true)
    }

    @Test("a fresh suite yields the documented defaults")
    func defaults() {
        let (defaults, suiteName) = tempSuite()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = MenuBarSettings(defaults: defaults)
        #expect(settings.refineModelName == MenuBarSettings.defaultRefineModelName)
        #expect(settings.systemAudioEnabled == true)
        #expect(settings.diarizeMicEnabled == false)
        #expect(settings.selectedMicDeviceID == nil)
        #expect(settings.outputFolderPath == nil)
        // No *stored* path, but `outputFolderURL` falls back to the default
        // (`~/Documents/PulsarTrace`) so a first run can record immediately.
        #expect(settings.outputFolderURL
            == MenuBarSettings.defaultOutputFolderURL)
        #expect(settings.outputFolderURL != nil)
        #expect(settings.globalHotkey == nil)
        #expect(settings.previousFolderPaths.isEmpty)
    }

    @Test("outputFolderURL defaults to ~/Documents/PulsarTrace; an explicit path wins; clearing re-defaults")
    func outputFolderDefaultsToDocuments() {
        let (defaults, suiteName) = tempSuite()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = MenuBarSettings(defaults: defaults)
        let documents = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask).first
        let expected = documents?.appendingPathComponent(
            "PulsarTrace", isDirectory: true)
        #expect(expected != nil)
        #expect(settings.outputFolderURL?.standardizedFileURL
            == expected?.standardizedFileURL)
        // The default is derived, never written into the store — clearing the
        // user's choice must re-default on the next read.
        #expect(defaults.string(forKey: "outputFolderPath") == nil)

        // An explicitly-set path still wins over the default…
        settings.outputFolderPath = "/Users/test/Chosen"
        #expect(settings.outputFolderURL?.path == "/Users/test/Chosen")

        // …and clearing it re-defaults (still without persisting the default).
        settings.outputFolderPath = nil
        #expect(settings.outputFolderURL?.standardizedFileURL
            == expected?.standardizedFileURL)
        #expect(defaults.string(forKey: "outputFolderPath") == nil)
    }

    @Test("legacy live-model keys are removed on load (PT-P5-D1)")
    func legacyLiveModelKeysRemoved() {
        let (suite, suiteName) = tempSuite()
        defer { suite.removePersistentDomain(forName: suiteName) }

        suite.set("large-v3", forKey: "modelName")      // pre-PT-P2-D11 single knob
        suite.set("base", forKey: "liveModelName")      // pre-PT-P5-D1 live knob
        let settings = MenuBarSettings(defaults: suite)
        #expect(suite.object(forKey: "modelName") == nil)
        #expect(suite.object(forKey: "liveModelName") == nil)
        #expect(settings.refineModelName == MenuBarSettings.defaultRefineModelName)
    }

    @Test("a persisted pre-PT-P5-D1 refine model name re-defaults to the ANE catalog")
    func staleRefineModelNameRedefaults() {
        let (suite, suiteName) = tempSuite()
        defer { suite.removePersistentDomain(forName: suiteName) }

        suite.set("large-v3", forKey: "refineModelName")   // retired ggml name
        let settings = MenuBarSettings(defaults: suite)
        #expect(settings.refineModelName == "large-v3-turbo")
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

    @Test("a legacy security-scoped bookmark migrates to a plain path (PT-P2-D12)")
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

        // Simulate a pre-PT-P2-D12 store: only the legacy bookmark keys are present.
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

    @Test("the new path key wins over a stale legacy bookmark (PT-P2-D12)")
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
