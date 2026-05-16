import Foundation

/// An event produced by an `AudioFrameSource`.
///
/// Every source produces a homogeneous stream of these so the engine can
/// handle pacing gaps and end-of-stream identically regardless of whether the
/// bytes came from a device, a fixture WAV, a pipe, or a socket (R75).
public enum AudioStreamEvent: Sendable, Equatable {
    /// A 20 ms PCM frame.
    case frame(AudioFrame)
    /// The source paused (e.g. system sleep, R77). Carries the wall-clock
    /// duration of the gap once known; the engine logs the gap.
    case paused
    /// The source resumed after a pause. `gap` is the elapsed paused time.
    case resumed(gap: Duration)
}

/// The central audio abstraction (R70).
///
/// Everything above this protocol — chunking, transcription, diarization,
/// file output — is written against `AudioFrameSource` and cannot tell whether
/// frames originated from a real device, a fixture WAV, stdin, or a Unix
/// socket. This is the seam that makes nine of ten epics testable without
/// audio hardware.
///
/// A source is an `AsyncSequence` of `AudioStreamEvent`. Iteration begins after
/// `start()` and ends with a clean `nil` from the iterator (end-of-stream).
/// Sources must not throw on normal termination; `stop()` requests early
/// termination and the iterator then finishes cleanly.
public protocol AudioFrameSource: AsyncSequence, Sendable where Element == AudioStreamEvent {
    /// Begin producing frames. Idempotent: a second call is a no-op.
    func start() async throws
    /// Request early termination. After this the async sequence finishes
    /// cleanly (the iterator returns `nil`); it never throws on stop.
    func stop() async
}
