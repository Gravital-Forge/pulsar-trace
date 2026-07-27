import Foundation
import PulsarTraceEngine

/// A keyboard shortcut for the global record toggle hotkey (PT-R41).
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

/// User-configurable menubar settings (PT-R42, PT-R43, PT-R41), persisted to
/// `UserDefaults`.
///
/// `@MainActor @Observable` so SwiftUI views observe it directly. Persistence
/// is to an injectable `UserDefaults` — production uses a named suite so the
/// settings live in the app's own domain; tests inject a throwaway suite.
///
/// The output folder is stored as a **plain filesystem path** (`String`).
/// PulsarTrace v1 is explicitly unsandboxed (a stated non-goal), so a
/// security-scoped bookmark — an App Sandbox mechanism — buys nothing and was
/// fragile across unsigned dev rebuilds (it resolved stale and the folder
/// selection was lost). See PT-P2-D12. A legacy `Data` bookmark from an earlier
/// install is migrated to a path once on load.
@MainActor
@Observable
public final class MenuBarSettings {

    /// The `UserDefaults` suite name the production app persists into.
    public static let defaultSuiteName = "com.gravitalforge.PulsarTrace"

    /// Default refine-pass model — Whisper large-v3-turbo on the ANE via
    /// WhisperKit (PT-P5-D1): near-large-v3 accuracy, ~626 MB, GPU-free.
    public static let defaultRefineModelName = WhisperKitModelCatalog.defaultModel.name

    /// Default output folder when the user has never chosen one:
    /// `~/Documents/PulsarTrace`. Derived at read time and **never persisted**
    /// — clearing `outputFolderPath` re-defaults on the next read. `nil` only
    /// in the theoretical case where the Documents directory cannot be
    /// resolved.
    public static var defaultOutputFolderURL: URL? {
        FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("PulsarTrace", isDirectory: true)
    }

    // MARK: - Persisted properties

    /// `AVCaptureDevice.uniqueID` of the chosen microphone, or `nil` for the
    /// system default mic (PT-R42).
    public var selectedMicDeviceID: String? {
        didSet { save() }
    }

    /// Refine-pass model name (PT-R43, PT-P5-D1) — a `WhisperKitModelCatalog` name;
    /// unknown/retired names re-default on load.
    public var refineModelName: String {
        didSet { save() }
    }

    /// Filesystem path of the output folder (PT-P2-D12). `nil` until the user picks
    /// a folder — but note `outputFolderURL` falls back to
    /// `defaultOutputFolderURL` when this is `nil`, so a first run records
    /// into `~/Documents/PulsarTrace` without any setup.
    public var outputFolderPath: String? {
        didSet { save() }
    }

    /// The global record-toggle hotkey (PT-R41), or `nil` if unset.
    public var globalHotkey: KeyCombo? {
        didSet { save() }
    }

    /// Whether system-audio capture is enabled (PT-R6). Default `true`.
    public var systemAudioEnabled: Bool {
        didSet { save() }
    }

    /// Filesystem paths of previously-used output folders, so the recordings
    /// list can still surface recordings made before the folder was changed.
    public var previousFolderPaths: [String] {
        didSet { save() }
    }

    /// Allow list of ISO-639-1 language codes the live pass is allowed to
    /// detect, e.g. `["en", "pl"]`. Empty (default) → unrestricted
    /// auto-detect (the legacy behaviour). When non-empty, the engine is
    /// launched with `--allowed-languages` and pre-detects per window,
    /// forcing the highest-probability **allowed** code. This is what
    /// stops the `nn` (Norwegian Nynorsk) misfires the user observed on
    /// English audio from poisoning the committer.
    ///
    /// The Settings UI multi-select toggles entries in/out of this array;
    /// callers downstream (`RecordingViewModel` → `RecordPlan`) consume
    /// it as-is. Order isn't meaningful — the engine picks argmax over
    /// the set — so the UI stores codes in catalog (display-name) order
    /// for determinism.
    public var allowedLanguages: [String] {
        didSet { save() }
    }

    /// Whether the opt-in loopback MCP control surface is enabled (PT-R115).
    /// Default `false` — the server never starts unless the user turns it on.
    public var mcpServerEnabled: Bool {
        didSet { save() }
    }

    /// The loopback port the MCP server binds (PT-R115). Default `8276`. A
    /// plain `Int` so this type stays MCP-module-free; `MCPController` narrows
    /// it to `UInt16` when it owns the server lifecycle.
    public var mcpServerPort: Int {
        didSet { save() }
    }

    // MARK: - Derived

    /// `outputFolderPath` as a file URL; falls back to
    /// `defaultOutputFolderURL` (`~/Documents/PulsarTrace`) when the user has
    /// never chosen a folder, so a brand-new install's first Start Recording
    /// works without visiting Settings. The fallback is computed — never
    /// written to `UserDefaults` — so clearing the path re-defaults. `nil`
    /// only when no folder is chosen *and* the Documents directory cannot be
    /// resolved.
    public var outputFolderURL: URL? {
        if let outputFolderPath {
            return URL(fileURLWithPath: outputFolderPath)
        }
        return Self.defaultOutputFolderURL
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
        /// Legacy live-model key (pre-D39) — removed on load; the live pass
        /// has exactly one backend now (parakeet-v3, not user-selectable).
        static let legacyLiveModelName = "liveModelName"
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
        static let mcpServerEnabled = "mcpServerEnabled"
        static let mcpServerPort = "mcpServerPort"
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
        // PT-P5-D1: the live model knob is gone (Parakeet is the only live
        // backend). Drop both stale keys — the pre-PT-P2-D11 single `modelName`
        // and the pre-PT-P5-D1 `liveModelName` — so they can never resurface,
        // same pattern as the legacy bookmark migrations below.
        store.removeObject(forKey: Key.legacyModelName)
        store.removeObject(forKey: Key.legacyLiveModelName)
        // A persisted pre-PT-P5-D1 refine name ("base"/"large-v3") names a
        // retired ggml backend — re-default to the ANE catalog (clean over
        // compat: no display shims for dead backends).
        self.refineModelName = store.string(forKey: Key.refineModelName)
            .flatMap { WhisperKitModelCatalog.model(named: $0)?.name }
            ?? Self.defaultRefineModelName
        // PT-P2-D12: the output folder is now a plain path. If the new key is absent
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

        // Same PT-P2-D12 migration for the previous-folders list.
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

        self.allowedLanguages = store.array(forKey: Key.allowedLanguages)
            as? [String] ?? []

        // PT-R115: the MCP control surface is opt-in and disabled by default;
        // the default port is 8276.
        self.mcpServerEnabled = store.object(forKey: Key.mcpServerEnabled)
            as? Bool ?? false
        self.mcpServerPort = store.object(forKey: Key.mcpServerPort)
            as? Int ?? 8276

        // Persist whatever the load resolved to — including the PT-P2-D11/PT-P2-D12
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
        defaults.set(refineModelName, forKey: Key.refineModelName)
        defaults.set(outputFolderPath, forKey: Key.outputFolderPath)
        defaults.set(systemAudioEnabled, forKey: Key.systemAudioEnabled)
        defaults.set(previousFolderPaths, forKey: Key.previousFolderPaths)
        defaults.set(allowedLanguages, forKey: Key.allowedLanguages)
        defaults.set(mcpServerEnabled, forKey: Key.mcpServerEnabled)
        defaults.set(mcpServerPort, forKey: Key.mcpServerPort)
        if let hotkey = globalHotkey,
           let data = try? JSONEncoder().encode(hotkey) {
            defaults.set(data, forKey: Key.globalHotkey)
        } else {
            defaults.removeObject(forKey: Key.globalHotkey)
        }
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
