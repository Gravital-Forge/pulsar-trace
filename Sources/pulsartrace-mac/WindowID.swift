/// Stable identifiers for the app's auxiliary windows (#6, #5).
///
/// A pure scene concern — these ids are passed to SwiftUI's `Window(_:id:)`
/// and `openWindow(id:)`, so they stay in the app target while the navigation
/// state (`AppNavigation` / `AppSection`) lives in `PulsarTraceMenuBar`.
enum WindowID {
    /// The unified app window — recordings / speakers / settings sidebar.
    static let main = "main"
    /// The detached live-transcript window.
    static let liveTranscript = "live-transcript"
}
