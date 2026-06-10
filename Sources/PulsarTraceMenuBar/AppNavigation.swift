// Sources/PulsarTraceMenuBar/AppNavigation.swift
import Foundation

/// A sidebar section of the unified app window (#6).
public enum AppSection: String, CaseIterable, Identifiable, Sendable {
    case recordings, refinements, speakers, settings

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .recordings:  return "Recordings"
        case .refinements: return "Refinements"
        case .speakers:    return "Speakers"
        case .settings:    return "Settings"
        }
    }

    public var systemImage: String {
        switch self {
        case .recordings:  return "waveform"
        case .refinements: return "arrow.triangle.2.circlepath"
        case .speakers:    return "person.2"
        case .settings:    return "gearshape"
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
public final class AppNavigation {
    /// The sidebar section the unified window currently shows.
    public var section: AppSection = .recordings

    /// The recording selected in the Recordings pane's master list (§4.1).
    /// Process-lifetime, like `section`, so the selection survives the window
    /// being closed and re-opened.
    public var selectedRecordingID: String?

    public init() {}
}
