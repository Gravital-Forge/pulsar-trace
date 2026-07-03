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
        // Never re-presented by the system at launch — see the type's doc.
        // Deliberately NO activation code here: this window only opens from
        // user actions, whose activation the dropdown's open() handles. A
        // launch-time `NSApp.activate()` from here is declined by
        // cooperative activation anyway — no user intent backs it (QA
        // rounds 4–7).
        .background(WindowRestorationOptOut())
    }

    /// The sidebar: the section list. Deliberately brandless in-content (§3) —
    /// the brand lives in the menubar icon and the window's title in the
    /// Windows menu; the per-pane `.navigationTitle` stays.
    private var sidebar: some View {
        List(AppSection.allCases, selection: sidebarSelection) { section in
            Label(section.title, systemImage: section.systemImage)
                .tag(section)
                // PT-P7-R3: identifier per sidebar entry. A `Label` carries
                // text, so it is a first-class AX element — no container
                // promotion needed.
                .accessibilityIdentifier(Self.sidebarID(section))
        }
    }

    /// Stable identifier for a sidebar entry (PT-P7-R3) — keyed on the section
    /// case, never the localized title, so the suite's lookup survives a title
    /// or localization change.
    private static func sidebarID(_ section: AppSection) -> String {
        switch section {
        case .recordings: return A11yID.Sidebar.recordings
        case .speakers:   return A11yID.Sidebar.speakers
        case .settings:   return A11yID.Sidebar.settings
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
