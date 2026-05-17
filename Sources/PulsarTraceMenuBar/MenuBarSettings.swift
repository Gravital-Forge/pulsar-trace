import Foundation

/// A keyboard shortcut for the global record toggle hotkey (R41).
///
/// `keyCode` is a `CGKeyCode`/`NSEvent.keyCode`; `modifiers` is the raw value
/// of an `NSEvent.ModifierFlags` (stored as a plain `UInt` so this type stays
/// free of AppKit and thus testable in the library).
public struct KeyCombo: Codable, Equatable, Sendable {
    /// Virtual key code (`NSEvent.keyCode`).
    public let keyCode: UInt16
    /// Raw value of the `NSEvent.ModifierFlags` mask.
    public let modifiers: UInt

    public init(keyCode: UInt16, modifiers: UInt) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

/// User-configurable menubar settings (R42, R43, R41), persisted to
/// `UserDefaults`.
///
/// `@MainActor @Observable` so SwiftUI views observe it directly. Persistence
/// is to an injectable `UserDefaults` — production uses a named suite so the
/// settings live in the app's own domain; tests inject a throwaway suite.
///
/// The output folder is stored as a **security-scoped bookmark** (`Data`) from
/// the start (D27) so a sandboxed Epic 10 build can re-resolve the user's
/// chosen folder across launches without re-prompting.
@MainActor
@Observable
public final class MenuBarSettings {

    /// The `UserDefaults` suite name the production app persists into.
    public static let defaultSuiteName = "com.gravitalforge.PulsarTrace"

    /// Default live-pass whisper model — `base` keeps the live pass fast and
    /// keeps a first run from pulling a 3 GB `large-v3` the user never asked
    /// for (mirrors `record`'s D24 default).
    public static let defaultLiveModelName = "base"

    /// Default refine-pass whisper model — `base` so a first run never pulls a
    /// 3 GB `large-v3` unasked; the user opts into `large-v3` in Settings (D29).
    public static let defaultRefineModelName = "base"

    // MARK: - Persisted properties

    /// `AVCaptureDevice.uniqueID` of the chosen microphone, or `nil` for the
    /// system default mic (R42).
    public var selectedMicDeviceID: String? {
        didSet { save() }
    }

    /// Whisper model name for the live pass (R43, D29) — fast model preferred.
    public var liveModelName: String {
        didSet { save() }
    }

    /// Whisper model name for the post-recording refine pass (R43, D29) —
    /// a higher-quality model is appropriate here (D4 documents `large-v3`).
    public var refineModelName: String {
        didSet { save() }
    }

    /// Security-scoped bookmark of the output folder (D27). `nil` until the
    /// user picks a folder.
    public var outputFolderBookmark: Data? {
        didSet { save() }
    }

    /// The global record-toggle hotkey (R41), or `nil` if unset.
    public var globalHotkey: KeyCombo? {
        didSet { save() }
    }

    /// Whether system-audio capture is enabled (R6). Default `true`.
    public var systemAudioEnabled: Bool {
        didSet { save() }
    }

    /// Bookmarks of previously-used output folders, so the recordings list can
    /// still surface recordings made before the folder was changed.
    public var previousFolderBookmarks: [Data] {
        didSet { save() }
    }

    // MARK: - Derived

    /// Resolve `outputFolderBookmark` into a usable folder URL, or `nil`.
    ///
    /// A stale bookmark is tolerated — it resolves best-effort; callers fall
    /// back to prompting the user again.
    public var outputFolderURL: URL? {
        Self.resolveBookmark(outputFolderBookmark)
    }

    /// Resolve every `previousFolderBookmarks` entry to a URL, dropping any
    /// that no longer resolve.
    public var previousFolderURLs: [URL] {
        previousFolderBookmarks.compactMap { Self.resolveBookmark($0) }
    }

    // MARK: - Storage

    private let defaults: UserDefaults

    private enum Key {
        static let micDeviceID = "selectedMicDeviceID"
        /// Legacy single-model key (pre-D29) — read once on load to migrate.
        static let legacyModelName = "modelName"
        static let liveModelName = "liveModelName"
        static let refineModelName = "refineModelName"
        static let outputFolderBookmark = "outputFolderBookmark"
        static let globalHotkey = "globalHotkey"
        static let systemAudioEnabled = "systemAudioEnabled"
        static let previousFolderBookmarks = "previousFolderBookmarks"
    }

    /// Load settings from `defaults` (default: the production suite).
    ///
    /// - Parameter defaults: injectable store — tests pass a temp suite.
    public init(defaults: UserDefaults? = nil) {
        let store = defaults
            ?? UserDefaults(suiteName: Self.defaultSuiteName)
            ?? .standard
        self.defaults = store

        self.selectedMicDeviceID = store.string(forKey: Key.micDeviceID)
        // D29 split the single `modelName` setting into live + refine models.
        // Migration: if the new keys are absent but the legacy key exists,
        // seed `liveModelName` from it (the live pass kept the same default);
        // `refineModelName` falls back to its own documented default.
        let legacyModelName = store.string(forKey: Key.legacyModelName)
        self.liveModelName = store.string(forKey: Key.liveModelName)
            ?? legacyModelName
            ?? Self.defaultLiveModelName
        self.refineModelName = store.string(forKey: Key.refineModelName)
            ?? Self.defaultRefineModelName
        // Drop the migrated-from legacy key so it cannot resurface in a future
        // migration. The new keys are persisted by the next `save()`.
        if legacyModelName != nil {
            store.removeObject(forKey: Key.legacyModelName)
        }
        self.outputFolderBookmark = store.data(forKey: Key.outputFolderBookmark)
        self.systemAudioEnabled = store.object(forKey: Key.systemAudioEnabled)
            as? Bool ?? true
        self.previousFolderBookmarks = (store.array(
            forKey: Key.previousFolderBookmarks) as? [Data]) ?? []

        if let hotkeyData = store.data(forKey: Key.globalHotkey) {
            self.globalHotkey = try? JSONDecoder().decode(
                KeyCombo.self, from: hotkeyData)
        } else {
            self.globalHotkey = nil
        }
    }

    /// Persist every property to the backing `UserDefaults`. Called by each
    /// `didSet`; also exposed for an explicit flush.
    public func save() {
        defaults.set(selectedMicDeviceID, forKey: Key.micDeviceID)
        defaults.set(liveModelName, forKey: Key.liveModelName)
        defaults.set(refineModelName, forKey: Key.refineModelName)
        defaults.set(outputFolderBookmark, forKey: Key.outputFolderBookmark)
        defaults.set(systemAudioEnabled, forKey: Key.systemAudioEnabled)
        defaults.set(previousFolderBookmarks, forKey: Key.previousFolderBookmarks)
        if let hotkey = globalHotkey,
           let data = try? JSONEncoder().encode(hotkey) {
            defaults.set(data, forKey: Key.globalHotkey)
        } else {
            defaults.removeObject(forKey: Key.globalHotkey)
        }
    }

    // MARK: - Bookmark helpers

    /// Create a security-scoped bookmark `Data` for a chosen output folder.
    public static func makeBookmark(for folderURL: URL) throws -> Data {
        try folderURL.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil)
    }

    /// Resolve a bookmark `Data` back into a folder URL. Returns `nil` when the
    /// bookmark cannot be resolved at all.
    private static func resolveBookmark(_ data: Data?) -> URL? {
        guard let data else { return nil }
        var isStale = false
        return try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale)
    }
}
