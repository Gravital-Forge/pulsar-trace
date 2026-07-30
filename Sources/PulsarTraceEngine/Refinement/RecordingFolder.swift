import Foundation

/// Resolves the per-recording folder layout (the "one folder per
/// recording" storage model) and dispatches the two `pulsartrace refine`
/// input shapes.
///
/// Storage model: a recording lives in its own folder holding the audio
/// WAV(s), `final.md`, `metadata.json` and `live.md`:
///
/// ```
/// 2026-04-30-team-standup/
///   audio-system.wav      ← system stream, diarized
///   audio-mic.wav         ← mic stream, label "You", never diarized (PT-R17)
///   live.md               ← provisional transcript
///   final.md              ← refined transcript
///   metadata.json         ← machine-readable sidecar
/// ```
///
/// `refine` accepts two input shapes (PT-P1-D13):
///
/// 1. **A recording folder** — already in the layout above. Outputs are
///    written back into it.
/// 2. **A bare WAV file** — treated as a single-stream recording. There is no
///    recording folder yet, so one is created as a *sibling* of the WAV named
///    for the WAV's stem (`meeting.wav` → `meeting/`), and the WAV is left
///    where it is — the folder's `metadata.json` records the source path's
///    basename. Putting outputs in a dedicated sibling folder keeps the user's
///    original audio file untouched and groups `final.md` + `metadata.json`
///    together, matching the "one folder per recording" model.
public struct RecordingFolder: Sendable {

    /// Canonical file names inside a recording folder.
    public enum FileName {
        public static let audioSystem = "audio-system.wav"
        public static let audioMic = "audio-mic.wav"
        public static let live = "live.md"
        public static let liveBackup = ".live.md.bak"
        public static let final = "final.md"
        public static let finalBackup = "final.md.bak"
        public static let metadata = "metadata.json"
        /// UI-owned custom-title sidecar — written by the mac app's rename
        /// flow, never read by the engine (spec §4.1).
        public static let title = "title.txt"
        /// PT-P8-R2 — per-recording input options sidecar (UI/CLI/MCP-owned).
        public static let options = "options.json"
    }

    public enum InputError: Error, CustomStringConvertible, Equatable {
        case pathNotFound(String)
        case notAWavOrFolder(String)
        case folderHasNoAudio(String)

        public var description: String {
            switch self {
            case .pathNotFound(let p):
                return "input path not found: \(p)"
            case .notAWavOrFolder(let p):
                return "input must be a .wav file or a recording folder: \(p)"
            case .folderHasNoAudio(let p):
                return "recording folder contains no \(FileName.audioSystem) "
                    + "(or any .wav): \(p)"
            }
        }
    }

    /// One audio stream feeding the refine pipeline.
    public struct Stream: Sendable {
        /// The WAV file backing this stream.
        public let url: URL
        /// True for the microphone stream — labelled `You`, never diarized (PT-R17).
        public let isMicrophone: Bool
    }

    /// The folder all outputs (`final.md`, `metadata.json`) are written into.
    public let directory: URL
    /// The recording id (`rec_<short>`), derived from the folder/WAV name.
    public let recordingId: String
    /// The system-audio stream — always diarized.
    public let systemStream: Stream
    /// The microphone stream, when present — labelled `You`, never diarized.
    public let micStream: Stream?

    /// `final.md` destination URL.
    public var finalURL: URL { directory.appendingPathComponent(FileName.final) }
    /// `metadata.json` destination URL.
    public var metadataURL: URL { directory.appendingPathComponent(FileName.metadata) }
    /// `options.json` input-sidecar URL (may or may not exist).
    public var optionsURL: URL { directory.appendingPathComponent(FileName.options) }
    /// `live.md` URL (may or may not exist).
    public var liveURL: URL { directory.appendingPathComponent(FileName.live) }

    /// Resolve a `refine` input path into a `RecordingFolder`.
    ///
    /// Dispatches on whether `inputPath` is a directory (recording folder) or a
    /// regular `.wav` file (bare-WAV input) — see the type doc for the rules.
    public static func resolve(inputPath: URL) throws -> RecordingFolder {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: inputPath.path, isDirectory: &isDir) else {
            throw InputError.pathNotFound(inputPath.path)
        }

        if isDir.boolValue {
            return try resolveFolder(inputPath)
        }
        guard inputPath.pathExtension.lowercased() == "wav" else {
            throw InputError.notAWavOrFolder(inputPath.path)
        }
        return resolveBareWav(inputPath)
    }

    // MARK: - Folder input

    /// A recording folder: locate `audio-system.wav` (+ optional `audio-mic.wav`).
    private static func resolveFolder(_ folder: URL) throws -> RecordingFolder {
        let fm = FileManager.default
        let systemURL = folder.appendingPathComponent(FileName.audioSystem)
        let micURL = folder.appendingPathComponent(FileName.audioMic)

        let systemStream: Stream
        if fm.fileExists(atPath: systemURL.path) {
            systemStream = Stream(url: systemURL, isMicrophone: false)
        } else {
            // Tolerate a folder whose system WAV is named otherwise (e.g. the
            // `mic-and-system-paired/` fixture uses `system.wav`/`mic.wav`):
            // fall back to any single `.wav` that is not the mic file.
            let wavs = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension.lowercased() == "wav" } ?? []
            guard let fallbackSystem = wavs.first(where: {
                let n = $0.lastPathComponent.lowercased()
                return n != "mic.wav" && n != FileName.audioMic
            }) ?? wavs.first else {
                throw InputError.folderHasNoAudio(folder.path)
            }
            systemStream = Stream(url: fallbackSystem, isMicrophone: false)
        }

        var micStream: Stream?
        if fm.fileExists(atPath: micURL.path) {
            micStream = Stream(url: micURL, isMicrophone: true)
        } else {
            let altMic = folder.appendingPathComponent("mic.wav")
            if fm.fileExists(atPath: altMic.path) {
                micStream = Stream(url: altMic, isMicrophone: true)
            }
        }

        return RecordingFolder(
            directory: folder,
            recordingId: recordingId(forName: folder.lastPathComponent),
            systemStream: systemStream,
            micStream: micStream)
    }

    // MARK: - Bare-WAV input

    /// A bare WAV: create a sibling output folder named for the WAV stem.
    private static func resolveBareWav(_ wav: URL) -> RecordingFolder {
        let stem = wav.deletingPathExtension().lastPathComponent
        let folder = wav.deletingLastPathComponent()
            .appendingPathComponent(stem, isDirectory: true)
        return RecordingFolder(
            directory: folder,
            recordingId: recordingId(forName: stem),
            // A bare WAV is a single stream — treated as system audio so it is
            // diarized; there is no separate mic stream, so no "You" label.
            systemStream: Stream(url: wav, isMicrophone: false),
            micStream: nil)
    }

    // MARK: - Recording id

    /// Derive a stable, filesystem-safe `rec_<short>` id from a folder/WAV name.
    ///
    /// Deterministic: the same input name always yields the same id, so a
    /// re-refine of the same recording reuses its id across runs.
    public static func recordingId(forName name: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        let slug = name.lowercased()
            .map { allowed.contains($0) ? $0 : "-" }
            .reduce(into: "") { acc, ch in
                // Collapse runs of "-" so the id stays tidy.
                if ch == "-" && acc.last == "-" { return }
                acc.append(ch)
            }
        let trimmed = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "rec_\(trimmed.isEmpty ? "recording" : trimmed)"
    }
}
