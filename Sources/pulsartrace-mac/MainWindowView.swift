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
        .frame(minWidth: 640, minHeight: 420)
    }

    /// The sidebar: the app's name as a brand heading, then the section list.
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("PulsarTrace")
                .font(.title2.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 6)
            List(AppSection.allCases, selection: sidebarSelection) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
        }
    }

    @ViewBuilder private var detail: some View {
        // `RecordingsScanner` / `MenuBarSettings` reach these panes through the
        // environment injected on this window's scene root (`PulsarTraceMacApp`).
        switch navigation.section {
        case .recordings:
            RecordingsListView()
        case .refinements:
            RefinementsListView()
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
