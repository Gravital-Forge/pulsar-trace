/// Accessibility identifiers for UI end-to-end tests (PT-P7-R3).
///
/// Convention: `pt.<surface>.<element>`, camelCase element names. Dynamic
/// rows append a **stable id** via the `row(_:)` helpers — a recording's
/// folder name, a speaker's `spk_<ulid>` — never a display name, so renames
/// and localization can never break element lookup. Views attach these with
/// `.accessibilityIdentifier(…)`; tests locate elements ONLY through these
/// constants. This file is the single home of the convention — add new
/// identifiers here first, then attach them.
// PT-P7-R3
public enum A11yID {
    /// The menu-bar status item (the `MenuBarExtra` label).
    public static let statusItem = "pt.statusItem"

    /// The menubar dropdown panel (`MenuBarMenuView`).
    public enum MenuBar {
        public static let panel = "pt.menubar.panel"
        public static let recordToggle = "pt.menubar.recordToggle"
        /// The "Recordings…" opener — opens the main window at the Recordings
        /// section (the row UI tests use to open the main window).
        public static let openRecordings = "pt.menubar.openRecordings"
        public static let openLiveTranscript = "pt.menubar.openLiveTranscript"
        public static let progressLabel = "pt.menubar.progressLabel"
        /// The "Speakers…" opener (opens the main window's Speakers pane).
        public static let openSpeakers = "pt.menubar.openSpeakers"
        /// The "Settings…" opener (opens the main window's Settings pane).
        public static let openSettings = "pt.menubar.openSettings"
        /// Crash-recovery: "Recover Transcript".
        public static let recoverTranscript = "pt.menubar.recoverTranscript"
        /// Crash/error: "Dismiss".
        public static let dismiss = "pt.menubar.dismiss"
        /// "Quit PulsarTrace".
        public static let quit = "pt.menubar.quit"
    }

    /// The unified main window (`MainWindowView`) sidebar.
    public enum Sidebar {
        public static let recordings = "pt.sidebar.recordings"
        public static let speakers = "pt.sidebar.speakers"
        public static let settings = "pt.sidebar.settings"
    }

    /// Recordings pane (`RecordingsSplitView`).
    public enum Recordings {
        public static let list = "pt.recordings.list"
        /// Row for one recording; `folderName` is the on-disk folder basename.
        public static func row(_ folderName: String) -> String {
            "pt.recordings.row.\(folderName)"
        }
    }

    /// Speakers pane (`SpeakerEditorView`).
    public enum Speakers {
        public static let list = "pt.speakers.list"
        /// Row for one speaker; `id` is the stable `spk_<ulid>`.
        public static func row(_ id: String) -> String {
            "pt.speakers.row.\(id)"
        }
        public static let renameField = "pt.speakers.renameField"
        /// The "Merge With" submenu (context menu). Merge is a submenu of
        /// per-speaker targets, not a single button — this ids the submenu; the
        /// per-target buttons under it carry `mergeTarget(_:)`.
        public static let mergeButton = "pt.speakers.mergeButton"
        /// One "Merge With ▸ ⟨speaker⟩" target; `id` is the stable `spk_<ulid>`
        /// of the speaker to fold into the right-clicked one, never a name.
        public static func mergeTarget(_ id: String) -> String {
            "pt.speakers.mergeTarget.\(id)"
        }
        public static let mergeConfirm = "pt.speakers.mergeConfirm"
        public static let deleteButton = "pt.speakers.deleteButton"
        public static let undoToast = "pt.speakers.undoToast"
        public static let undoButton = "pt.speakers.undoButton"
    }

    /// Settings pane (`SettingsView`).
    public enum Settings {
        public static let micPicker = "pt.settings.micPicker"
        public static let refineModelPicker = "pt.settings.refineModelPicker"
        public static let outputFolderField = "pt.settings.outputFolderField"
        public static let chooseFolderButton = "pt.settings.chooseFolderButton"
        public static let systemAudioToggle = "pt.settings.systemAudioToggle"
        public static let hotkeyRecorder = "pt.settings.hotkeyRecorder"
        public static let languageSection = "pt.settings.languageSection"
        public static let mcpToggle = "pt.settings.mcpToggle"
        public static let mcpPortField = "pt.settings.mcpPortField"
    }

    /// Main-window toolbar (`RecordToolbarButton`) — distinct from the
    /// panel's record rows so the two surfaces never collide in a query.
    public enum Window {
        public static let recordToolbar = "pt.window.recordToolbar"
    }

    /// Detached live-transcript window (`LiveTranscriptView`).
    public enum LiveTranscript {
        public static let window = "pt.liveTranscript.window"
        public static let list = "pt.liveTranscript.list"
    }
}
