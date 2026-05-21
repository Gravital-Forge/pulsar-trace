// Sources/PulsarTraceEngine/Refinement/Jobs/RecordingFolderTimestamp.swift
import Foundation

/// Inverse of `RecordingViewModel.recordingFolderName(at:)`: parses the
/// `yyyy-MM-dd-HHmmss` prefix the menubar writes into each recording folder
/// name into the real recording-start `Date`. Returns `nil` when the prefix
/// is missing or malformed — the CLI's bare-WAV input has no such prefix.
public enum RecordingFolderTimestamp {

    /// The exact prefix length: 4 (year) + 1 + 2 (month) + 1 + 2 (day) + 1
    /// + 6 (HHmmss).
    private static let prefixLength = 17

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current   // matches the menubar writer's local-time format
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f
    }()

    /// Parse the timestamp prefix of `folderName`. Returns `nil` if the
    /// folder name does not start with a full `yyyy-MM-dd-HHmmss` prefix.
    public static func parse(_ folderName: String) -> Date? {
        guard folderName.count >= prefixLength else { return nil }
        let prefix = String(folderName.prefix(prefixLength))
        return formatter.date(from: prefix)
    }
}
