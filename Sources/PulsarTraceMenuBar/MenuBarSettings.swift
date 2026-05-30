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
/// The output folder is stored as a **plain filesystem path** (`String`).
/// PulsarTrace v1 is explicitly unsandboxed (PRD §17 non-goals), so a
/// security-scoped bookmark — an App Sandbox mechanism — buys nothing and was
/// fragile across unsigned dev rebuilds (it resolved stale and the folder
/// selection was lost). See D30. A legacy `Data` bookmark from an earlier
/// install is migrated to a path once on load.
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

    /// Filesystem path of the output folder (D30). `nil` until the user picks
    /// a folder.
    public var outputFolderPath: String? {
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

    /// Filesystem paths of previously-used output folders, so the recordings
    /// list can still surface recordings made before the folder was changed.
    public var previousFolderPaths: [String] {
        didSet { save() }
    }

    /// User-typed allow list of ISO-639-1 language codes the live pass is
    /// allowed to detect, e.g. `"en, pl"`. Empty (default) → unrestricted
    /// auto-detect (the legacy behaviour). When non-empty, the engine is
    /// launched with `--allowed-languages` and pre-detects per window,
    /// forcing the highest-probability **allowed** code. This is what
    /// stops the `nn` (Norwegian Nynorsk) misfires the user observed on
    /// English audio from poisoning the committer.
    ///
    /// Stored raw so the SwiftUI `TextField` can bind to it directly
    /// without round-trip parse-corruption during typing. The parsed
    /// canonical form is `allowedLanguages` (computed).
    public var allowedLanguagesRaw: String {
        didSet { save() }
    }

    /// The parsed, canonical allow list — what callers feed downstream
    /// (e.g. `RecordPlan.make(allowedLanguages:)`). Empty when the user
    /// hasn't typed anything.
    public var allowedLanguages: [String] {
        Self.parseAllowedLanguages(allowedLanguagesRaw)
    }

    // MARK: - Derived

    /// `outputFolderPath` as a file URL, or `nil` when no folder is chosen.
    public var outputFolderURL: URL? {
        outputFolderPath.map { URL(fileURLWithPath: $0) }
    }

    /// Every `previousFolderPaths` entry as a file URL.
    public var previousFolderURLs: [URL] {
        previousFolderPaths.map { URL(fileURLWithPath: $0) }
    }

    // MARK: - Storage

    private let defaults: UserDefaults

    private enum Key {
        static let micDeviceID = "selectedMicDeviceID"
        /// Legacy single-model key (pre-D29) — read once on load to migrate.
        static let legacyModelName = "modelName"
        static let liveModelName = "liveModelName"
        static let refineModelName = "refineModelName"
        static let outputFolderPath = "outputFolderPath"
        /// Legacy security-scoped bookmark key (pre-D30) — read once to migrate.
        static let legacyOutputFolderBookmark = "outputFolderBookmark"
        static let globalHotkey = "globalHotkey"
        static let systemAudioEnabled = "systemAudioEnabled"
        static let previousFolderPaths = "previousFolderPaths"
        /// Legacy bookmark-array key (pre-D30) — read once to migrate.
        static let legacyPreviousFolderBookmarks = "previousFolderBookmarks"
        static let allowedLanguages = "allowedLanguages"
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
        // D30: the output folder is now a plain path. If the new key is absent
        // but a legacy security-scoped bookmark exists, best-effort resolve it
        // once to a path (no security scope — v1 is unsandboxed), then drop the
        // legacy key. If it cannot resolve, leave the output folder unset.
        if let path = store.string(forKey: Key.outputFolderPath) {
            self.outputFolderPath = path
        } else if let legacy = store.data(
            forKey: Key.legacyOutputFolderBookmark) {
            self.outputFolderPath = Self.resolveLegacyBookmark(legacy)?.path
        } else {
            self.outputFolderPath = nil
        }
        if store.object(forKey: Key.legacyOutputFolderBookmark) != nil {
            store.removeObject(forKey: Key.legacyOutputFolderBookmark)
        }

        self.systemAudioEnabled = store.object(forKey: Key.systemAudioEnabled)
            as? Bool ?? true

        // Same D30 migration for the previous-folders list.
        if let paths = store.array(
            forKey: Key.previousFolderPaths) as? [String] {
            self.previousFolderPaths = paths
        } else if let legacy = store.array(
            forKey: Key.legacyPreviousFolderBookmarks) as? [Data] {
            self.previousFolderPaths = legacy.compactMap {
                Self.resolveLegacyBookmark($0)?.path
            }
        } else {
            self.previousFolderPaths = []
        }
        if store.object(forKey: Key.legacyPreviousFolderBookmarks) != nil {
            store.removeObject(forKey: Key.legacyPreviousFolderBookmarks)
        }

        if let hotkeyData = store.data(forKey: Key.globalHotkey) {
            self.globalHotkey = try? JSONDecoder().decode(
                KeyCombo.self, from: hotkeyData)
        } else {
            self.globalHotkey = nil
        }

        self.allowedLanguagesRaw = store.string(forKey: Key.allowedLanguages)
            ?? ""

        // Persist whatever the load resolved to — including the D29/D30
        // migrations above. Pre-2026-05-29 this happened implicitly via an
        // `@Observable` macro quirk that fired `didSet` on the last stored
        // property; adding a new last property silently broke that path.
        // Making it explicit removes the dependency on macro details and
        // guarantees migrated state survives the next load.
        save()
    }

    /// Persist every property to the backing `UserDefaults`. Called by each
    /// `didSet`; also exposed for an explicit flush.
    public func save() {
        defaults.set(selectedMicDeviceID, forKey: Key.micDeviceID)
        defaults.set(liveModelName, forKey: Key.liveModelName)
        defaults.set(refineModelName, forKey: Key.refineModelName)
        defaults.set(outputFolderPath, forKey: Key.outputFolderPath)
        defaults.set(systemAudioEnabled, forKey: Key.systemAudioEnabled)
        defaults.set(previousFolderPaths, forKey: Key.previousFolderPaths)
        defaults.set(allowedLanguagesRaw, forKey: Key.allowedLanguages)
        if let hotkey = globalHotkey,
           let data = try? JSONEncoder().encode(hotkey) {
            defaults.set(data, forKey: Key.globalHotkey)
        } else {
            defaults.removeObject(forKey: Key.globalHotkey)
        }
    }

    // MARK: - Allowed-languages helpers

    /// Parse a human-typed list of language codes (e.g. `"en, pl"`) into the
    /// canonical storage form: lowercase, whitespace-trimmed, empties
    /// dropped, original order preserved. Used by the Settings TextField so
    /// "en, PL" and " en ,pl " both land as `["en", "pl"]`.
    public static func parseAllowedLanguages(_ raw: String) -> [String] {
        raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }

    // MARK: - Legacy migration

    /// Best-effort resolve a pre-D30 security-scoped bookmark `Data` into a
    /// folder URL, used once at load to migrate an old install to a plain path.
    /// Resolves *without* security scope (v1 is unsandboxed); returns `nil`
    /// when the bookmark cannot be resolved at all.
    private static func resolveLegacyBookmark(_ data: Data) -> URL? {
        var isStale = false
        return try? URL(
            resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale)
    }
}
