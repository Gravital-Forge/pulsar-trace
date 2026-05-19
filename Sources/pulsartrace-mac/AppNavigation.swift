import SwiftUI

/// Stable identifiers for the app's auxiliary windows (#6, #5).
enum WindowID {
    /// The unified app window — recordings / speakers / settings sidebar.
    static let main = "main"
    /// The detached live-transcript window.
    static let liveTranscript = "live-transcript"
}

/// A sidebar section of the unified app window (#6).
enum AppSection: String, CaseIterable, Identifiable {
    case recordings, speakers, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recordings: return "Recordings"
        case .speakers: return "Speakers"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .recordings: return "waveform"
        case .speakers: return "person.2"
        case .settings: return "gearshape"
        }
    }
}

/// Shared navigation state for the unified window (#6).
///
/// The menubar items set `section` and then open the window, so it always
/// lands on the pane the user asked for. Lives in `AppEnvironment` for the
/// process lifetime so the selection survives the window being closed and
/// re-opened.
@MainActor
@Observable
final class AppNavigation {
    /// The sidebar section the unified window currently shows.
    var section: AppSection = .recordings
}
