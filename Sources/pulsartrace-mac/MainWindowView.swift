import PulsarTraceEngine
import PulsarTraceMenuBar
import SwiftUI

/// The unified app window (#6) — a sidebar over the Recordings, Speakers, and
/// Settings panes.
///
/// Replaces the inline-page navigation that previously rendered these views
/// *inside* the `MenuBarExtra` panel ("FIX 2"). They now live in a real,
/// resizable window: the menubar dropdown is a plain panel again, and a
/// `.sheet` (merge/split, the transcript viewer) positions correctly because
/// it is presented on an ordinary window rather than a menubar panel.
///
/// ## Sidebar pane chrome rule
/// Every view that appears in the `detail` column (see `detail` below) MUST
/// carry a `.toolbar {}` modifier — even a toolbar with only a single item.
/// Without it, macOS's `NavigationSplitView` renders different corner rounding
/// and a different sidebar visual boundary: the three traffic-light circles
/// appear outside the sidebar outline rather than inside it. The canonical
/// explanation lives in the toolbar comment in `SettingsView.swift`. All three detail panes
/// (`RecordingsSplitView`, `SpeakerEditorView`, `SettingsView`) follow this
/// rule.
struct MainWindowView: View {
    /// The process-wide events writer — handed to the speaker editor so its
    /// `speaker_*` / `final_md_rewritten` events are emitted in the shipped app.
    let events: EventWriter

    @Environment(AppNavigation.self) private var navigation

    var body: some View {
        // `columnVisibility` is pinned to `.all` and the sidebar-toggle button
        // is removed (below): the sidebar never collapses. Collapsing animated
        // the detail pane briefly out of the viewport, flashing the toggle
        // chevrons — not worth keeping for a three-item sidebar.
        NavigationSplitView(columnVisibility: .constant(.all)) {
            sidebar
                .navigationSplitViewColumnWidth(210)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            detail
                .navigationTitle(navigation.section.title)
        }
        .frame(minWidth: 800, minHeight: 420)
        .onAppear { activateOnLaunchRestore() }
    }

    /// Accessory-policy apps (no Dock icon, D27) are not activated by macOS
    /// when a window opens, so the window SwiftUI restores at launch came up
    /// with the app inactive — every control drawn in its greyed
    /// window-background appearance until the user bounced focus away and
    /// back (QA round 4). A bare `NSApp.activate()` in `onAppear` did NOT
    /// fix it (QA round 5): at launch-restore `onAppear` runs while the app
    /// is still finishing its launch, and the accessory launch path leaves
    /// the app deactivated *after* that early request. Deferring one
    /// run-loop turn lands the request after launch completes.
    ///
    /// Deliberately NO `makeKeyAndOrderFront` here: if the system declines
    /// the activation (it may — there is no user interaction to back it at
    /// launch), forcing the window key anyway produces a key window in an
    /// inactive app. That zombie receives clicks directly, so AppKit's
    /// click-to-activate never fires — the window stays greyed yet its
    /// controls respond (QA round 6). Worst case without it: the restored
    /// window comes up inactive and the user's first click activates it.
    private func activateOnLaunchRestore() {
        DispatchQueue.main.async {
            NSApp.activate()
        }
    }

    /// The sidebar: the section list. Deliberately brandless in-content (§3) —
    /// the brand lives in the menubar icon and the window's title in the
    /// Windows menu; the per-pane `.navigationTitle` stays.
    private var sidebar: some View {
        List(AppSection.allCases, selection: sidebarSelection) { section in
            Label(section.title, systemImage: section.systemImage)
                .tag(section)
        }
    }

    @ViewBuilder private var detail: some View {
        // `RecordingsScanner` / `MenuBarSettings` reach these panes through the
        // environment injected on this window's scene root (`PulsarTraceMacApp`).
        switch navigation.section {
        case .recordings:
            RecordingsSplitView()
        case .speakers:
            SpeakerEditorView(events: events)
        case .settings:
            SettingsView()
        }
    }

    /// `List` selection must be optional; `navigation.section` is not. Bridge
    /// the two — a `nil` set (the user cannot deselect the only column) is
    /// ignored.
    private var sidebarSelection: Binding<AppSection?> {
        Binding(
            get: { navigation.section },
            set: { if let new = $0 { navigation.section = new } })
    }
}
