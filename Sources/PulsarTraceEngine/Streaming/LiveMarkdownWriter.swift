import Foundation

/// Strictly append-only writer for a recording's `live.md` (Epic 6 — R12,
/// R35, R35a, R36, R37).
///
/// `live.md` is one of PulsarTrace's three public API surfaces: an external AI
/// agent `tail -f`s it during a meeting. Two hard invariants govern it:
///
/// - **R35a / R37** — the file is created **at session start**, before the
///   first utterance, carrying the `<!-- pulsartrace:live -->` marker and the
///   `## Transcript — YYYY-MM-DD HH:MM` header. An agent attaching mid-meeting
///   sees an unambiguous "recording in progress" signal even before any speech.
/// - **R36 / R12** — every write is a **whole line appended to the end**. The
///   file is never rewritten, never edited in place, never truncated. A
///   speaker rename mid-call applies to the next post-pass, never here. A
///   `tail -f` consumer therefore sees **strictly monotonic byte growth** and
///   never a torn line or a partial UTF-8 character.
///
/// This is deliberately *not* built on `AtomicFile` (which write-then-renames
/// the whole file): an atomic whole-file replace would break the append-only
/// `tail -f` contract — the inode would change under the reader on every
/// utterance. Instead the writer holds one `FileHandle` open for the session
/// and appends each line directly to its file descriptor.
///
/// The append is **fully robust** (R12 — append-only is a hard invariant): the
/// line is UTF-8 encoded *before* the write (so a multi-byte character is never
/// cut), and the bytes are written via a `write(2)` loop on the raw descriptor
/// that retries on `EINTR` and on a short write until **every** byte has
/// landed (or throws on a genuine error). `FileHandle.write(contentsOf:)` does
/// not do this — POSIX `write(2)` may return a short count if a signal (e.g. a
/// `SIGCHLD` from a captive subprocess) interrupts it mid-write, and a partial
/// append would leave a torn line in `live.md`. The loop guarantees a reader
/// eventually observes the whole line's bytes, in order, with no gaps.
///
/// An `actor` so concurrent producers (the streaming transcriber and the live
/// diarizer both feed lines) cannot interleave a half-line.
public actor LiveMarkdownWriter {

    public enum WriteError: Error, CustomStringConvertible {
        case alreadyStarted
        case notStarted
        case openFailed(String)
        case writeFailed(String)

        public var description: String {
            switch self {
            case .alreadyStarted: return "live.md writer already started"
            case .notStarted: return "live.md writer not started"
            case .openFailed(let p): return "could not open live.md for append: \(p)"
            case .writeFailed(let p): return "could not append to live.md: \(p)"
            }
        }
    }

    /// Destination `live.md` URL.
    public let fileURL: URL
    private let recordingStart: Date
    private var handle: FileHandle?
    /// Running byte total — every append advances it; exposed so tests can
    /// assert strictly monotonic growth (R36).
    public private(set) var bytesWritten: Int = 0

    /// - Parameters:
    ///   - fileURL: the `live.md` path inside the recording folder.
    ///   - recordingStart: wall-clock recording start for the R35a header.
    public init(fileURL: URL, recordingStart: Date) {
        self.fileURL = fileURL
        self.recordingStart = recordingStart
    }

    /// Create `live.md` at session start with the marker + header (R35a, R37).
    ///
    /// Writes the two header lines and leaves the handle open for the session.
    /// Idempotent-guarded: a second call throws rather than silently truncating
    /// (which would violate append-only).
    public func start() throws {
        guard handle == nil else { throw WriteError.alreadyStarted }

        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)

        // Create the file fresh. A pre-existing live.md (a previous, crashed
        // run) is overwritten *only here at session start* — never mid-session.
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        guard let h = try? FileHandle(forWritingTo: fileURL) else {
            throw WriteError.openFailed(fileURL.lastPathComponent)
        }
        self.handle = h

        // R35a/R37: marker first, then the header — exactly the `final.md`
        // header shape but with the `live` marker.
        let header = TranscriptDocument.Marker.live.rawValue + "\n"
            + "## Transcript — \(Self.headerFormatter.string(from: recordingStart))\n"
            + "\n"
        try appendRaw(header)
    }

    /// Append one fully-formed utterance line (R12, R36).
    ///
    /// `line` must be a single transcript line **without** a trailing newline;
    /// this method adds exactly one. The whole line is appended atomically.
    public func appendLine(_ line: String) throws {
        guard handle != nil else { throw WriteError.notStarted }
        try appendRaw(line + "\n")
    }

    /// Append a formatted utterance line for a streaming utterance.
    ///
    /// Renders the R13/Appendix shape: `**[HH:MM:SS] <speaker>:** <text>`.
    /// `speakerLabel` already carries any `(provisional)` suffix the caller
    /// wants (mic is `You`, system speakers are `Them (provisional)` etc.).
    public func appendUtterance(
        offset: Duration,
        speakerLabel: String,
        text: String
    ) throws {
        let stamp = TranscriptDocument.offsetStamp(offset)
        try appendLine("**[\(stamp)] \(speakerLabel):** \(text)")
    }

    /// A capture pause/resume to annotate in `live.md` (Epic 7, R7).
    public enum GapKind: Sendable {
        /// Capture paused — the Mac slept or the audio device changed.
        case paused
        /// Capture resumed; carries how long it was paused.
        case resumed(Duration)
    }

    /// Append a gap-annotation line marking a capture pause or resume (R7).
    ///
    /// Rendered as an italic note (`_(recording paused)_`) — the same line
    /// kind `final.md` uses for "no speech detected", clearly distinct from an
    /// utterance line. An optional annotation line is a non-breaking format
    /// addition (`docs/file-format.md`, Versioning).
    public func appendGapAnnotation(_ kind: GapKind) throws {
        guard handle != nil else { throw WriteError.notStarted }
        switch kind {
        case .paused:
            try appendLine("_(recording paused)_")
        case .resumed(let gap):
            try appendLine("_(recording resumed after \(Self.formatGap(gap)))_")
        }
    }

    /// fsync and close the handle — call at end of session. Idempotent.
    public func finish() {
        try? handle?.synchronize()
        try? handle?.close()
        handle = nil
    }

    // MARK: - Private

    /// The one true write primitive: UTF-8 encode, then a `write(2)` loop on
    /// the raw file descriptor that retries on `EINTR`/short writes until every
    /// byte has landed. Encoding before the write guarantees no partial
    /// multi-byte character ever reaches the file; the loop guarantees the
    /// whole line is appended even if a signal interrupts the syscall (R12 —
    /// `live.md` append-only is a hard invariant).
    private func appendRaw(_ text: String) throws {
        guard let handle else { throw WriteError.notStarted }
        let data = Data(text.utf8)
        guard !data.isEmpty else { return }
        let fd = handle.fileDescriptor

        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            let total = raw.count
            while offset < total {
                let n = write(fd, base + offset, total - offset)
                if n > 0 {
                    offset += n
                    continue
                }
                if n == -1 && errno == EINTR {
                    // Interrupted by a signal before any byte was written
                    // (e.g. a SIGCHLD from a captive subprocess) — retry.
                    continue
                }
                // A genuine write error: surface it rather than leaving a
                // torn line silently behind.
                throw WriteError.writeFailed(
                    "\(fileURL.lastPathComponent): write(2) failed (errno \(errno))")
            }
        }
        bytesWritten += data.count
    }

    /// Format a pause gap for a resume annotation: `45s`, `2m 05s`.
    private nonisolated static func formatGap(_ gap: Duration) -> String {
        let total = max(0, Int(gap.components.seconds))
        let minutes = total / 60
        let seconds = total % 60
        if minutes > 0 {
            return "\(minutes)m \(String(format: "%02d", seconds))s"
        }
        return "\(seconds)s"
    }

    /// `YYYY-MM-DD HH:MM` local-time header stamp (R35a) — identical shape to
    /// `TranscriptDocument`'s `final.md` header.
    private nonisolated static let headerFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
}
