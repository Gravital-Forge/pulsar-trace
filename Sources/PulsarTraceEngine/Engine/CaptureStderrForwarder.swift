import Foundation
import Logging

/// Continuously drains the capture daemon's stderr pipe and forwards its own
/// operational diagnostics into the engine's operational log.
///
/// The capture daemon (`pulsartrace-capture`) writes path-free diagnostics to
/// stderr prefixed with `"pulsartrace-capture: "` (see
/// `DeviceCaptureSource.log(_:)` / `SampleBufferConverter.log(_:)`). During a
/// real 62-min incident the daemon logged a microphone stall + several restart
/// attempts + recovery, but the orchestrator had already switched the pipe to a
/// void drain after the `ready` handshake, so none of it reached
/// `~/Library/Logs/PulsarTrace/<day>.log`. This forwarder replaces that void
/// drain so the daemon's diagnostics are visible without ever risking a leak.
///
/// Two hard constraints shape the design:
///
///  1. **Never block the child.** A full stderr pipe parks the writing
///     subprocess in `write()` — the root cause of the historical live-diarizer
///     "wedge" (PT-P5-D7). The reader therefore consumes every chunk regardless
///     of content, on a background reader, buffering partial lines across chunk
///     boundaries.
///  2. **Never leak (Hard Invariant #7).** The operational log must never carry
///     audio/transcript content, speaker names, or full user file paths. Only
///     lines beginning with the `"pulsartrace-capture: "` prefix are path-free
///     by construction; arbitrary AVFoundation/CoreAudio spew (which may embed
///     paths) is dropped. Forwarded lines have the prefix stripped and are
///     capped at ``maxLineLength`` characters; the partial-line carry buffer is
///     capped at ``maxBufferBytes`` and dropped wholesale if a line never
///     arrives, so it can never grow unbounded.
final class CaptureStderrForwarder: @unchecked Sendable {

    /// The daemon's stderr log prefix — path-free by construction. Only lines
    /// starting with this are forwarded.
    static let prefix = "pulsartrace-capture: "

    /// A forwarded line is truncated to this many characters (simple cut, no
    /// ellipsis) so a runaway line cannot bloat the operational log.
    static let maxLineLength = 512

    /// The partial-line carry buffer is dropped if it grows past this without a
    /// newline, so a newline-free flood cannot grow it unbounded.
    static let maxBufferBytes = 64 * 1024

    private let logger: Logger
    private let handle: FileHandle
    /// Partial-line carry across chunk boundaries. Only touched on the reader's
    /// serial delivery, so no additional locking is needed.
    private var carry = Data()

    init(handle: FileHandle, logger: Logger) {
        self.handle = handle
        self.logger = logger
    }

    /// Begin draining the pipe on a background reader. Terminates cleanly on
    /// EOF (the handler is niled out so it does not leak).
    func start() {
        let handle = self.handle
        handle.readabilityHandler = { [weak self] fh in
            let chunk = fh.availableData
            if chunk.isEmpty {
                // EOF — the daemon's stderr closed. Flush any trailing partial
                // line (defensive: the daemon newline-terminates, but a final
                // unterminated line should not be silently dropped), then tear
                // the handler down so it does not leak.
                self?.flushCarry()
                fh.readabilityHandler = nil
                return
            }
            self?.ingest(chunk)
        }
    }

    /// Feed a raw stderr chunk: append to the carry buffer, split on newlines,
    /// forward complete lines, and keep the trailing partial for next time.
    /// `internal` so the unit test can drive it directly without a live pipe.
    func ingest(_ chunk: Data) {
        carry.append(chunk)
        // Cap the carry buffer: if it has grown past the ceiling without a
        // newline, the writer is spewing newline-free garbage — drop it so the
        // buffer never grows unbounded. A carry that already contains a newline
        // is left alone; the loop below will drain it.
        if carry.count > Self.maxBufferBytes && !carry.contains(0x0A) {
            carry.removeAll(keepingCapacity: false)
            return
        }
        while let nl = carry.firstIndex(of: 0x0A) {
            let lineData = carry[carry.startIndex..<nl]
            forward(lineData)
            // Drop the line plus its newline.
            carry.removeSubrange(carry.startIndex...nl)
        }
    }

    /// Flush a trailing partial line at EOF (if any), then clear the buffer.
    private func flushCarry() {
        if !carry.isEmpty {
            forward(carry[carry.startIndex..<carry.endIndex])
            carry.removeAll(keepingCapacity: false)
        }
    }

    /// Forward one raw (newline-stripped) line if it is a daemon diagnostic:
    /// prefix-filter, strip the prefix, cap the length, log at `notice`.
    private func forward(_ lineData: Data) {
        guard let text = String(data: lineData, encoding: .utf8) else { return }
        // Trim a trailing CR so CRLF-terminated lines match the prefix too.
        let line = text.hasSuffix("\r") ? String(text.dropLast()) : text
        guard line.hasPrefix(Self.prefix) else { return }
        var message = String(line.dropFirst(Self.prefix.count))
        if message.count > Self.maxLineLength {
            message = String(message.prefix(Self.maxLineLength))
        }
        logger.notice("\(message)")
    }
}
