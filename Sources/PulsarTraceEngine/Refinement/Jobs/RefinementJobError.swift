// Sources/PulsarTraceEngine/Refinement/Jobs/RefinementJobError.swift
import Foundation

/// Classifies errors that propagate from `_runJob` into stable, UI-safe
/// identifiers. Drives the `errorClass` and `retryAvailable` fields of
/// `RefinementJobState.failed`.
///
/// Error sources surveyed (via `makeStandard`'s `runJob` closure):
/// - `OfflineRefiner.makeDiarizer` → `Diarizer.DiarizeError` (.pythonNotFound,
///   .launchFailed)
/// - `ResumableRefiner.run` → `Diarizer.DiarizeError` (non-.cancelled variants),
///   `TranscriptionError` from `WhisperKitRegionTranscriber` (incl.
///   `.decodeDeadlineExceeded`), `CancellationError` from a recording-start
///   decode cancel, I/O errors from `WAVReader` / `AtomicFile`.
/// - `FluidVADRegionDetector.detectRegions` → VAD load/run failures (the queue
///   closure falls back to a whole-stream region rather than failing the job).
/// - `TranscriptAssembly.assembleAndWrite` → `RefinementPipeline.RefineError`
///   (when the assemble step's reconciler / file writes wrap into the typed
///   RefineError). Each `RefineError` branch maps to a queue bucket.
///
/// CancellationError note: there are TWO cancellation shapes, handled
/// differently. (1) The diarizer's `.cancelled` case is caught *inside*
/// `ResumableRefiner.runDiarization` and retried when the pause gate reopens —
/// it never surfaces here. (2) A recording-start decode cancel
/// (`WhisperKitRegionTranscriber.cancelPending` → `decode` throws
/// `CancellationError`) DOES propagate out of the refiner — the per-region
/// retry loop catches only `TranscriptionError`. It also covers the worker's
/// next `box.get()` throwing after a pause in a NON-decode window POISONED the
/// box. In both cases the cancel never reaches `classify`:
/// `RefinementJobQueue.runNext` intercepts ANY `CancellationError`
/// UNCONDITIONALLY and *requeues the same job* with its checkpoint intact rather
/// than failing it (see the queue's pause doc). The `CancellationError →
/// .transcribeFailed` arm below is therefore unreachable from the queue path but
/// kept as a defensive fallback for any other caller — if a cancel ever surfaces
/// here, a retryable transcribe-failure is the right classification.
public enum RefinementJobError: Error {

    // MARK: - Stable error identifiers

    /// The diarization subprocess crashed or exited non-zero.
    /// Transient — the Python layer may succeed on a retry. `retryAvailable: true`.
    case diarizeCrashed

    /// A transcription step failed (WAV decode, Whisper error).
    /// Transient for I/O reasons; permanent for malformed input. We treat it as
    /// retryable since we cannot always distinguish the two.
    case transcribeFailed

    /// The Python interpreter or the diarization entry point was not found.
    /// Permanent until the environment is fixed. `retryAvailable: false`.
    case missingDependency

    /// Fallback: any error not matched above (unexpected I/O, encode, etc.).
    case io

    // MARK: - Derived properties

    /// Stable ASCII string stored in `RefinementJobState.failed.errorClass`.
    public var errorClass: String {
        switch self {
        case .diarizeCrashed:    return "diarizeCrashed"
        case .transcribeFailed:  return "transcribeFailed"
        case .missingDependency: return "missingDependency"
        case .io:                return "io"
        }
    }

    /// `true` for transient failures the user can retry; `false` for permanent ones.
    public var retryAvailable: Bool {
        switch self {
        case .diarizeCrashed:    return true
        case .transcribeFailed:  return true
        case .missingDependency: return false
        case .io:                return true
        }
    }

    // MARK: - Classifier

    /// Map any thrown `Error` to a `RefinementJobError`.
    ///
    /// Priority:
    /// 1. `Diarizer.DiarizeError` — subprocess-level failures.
    /// 2. `RefinementPipeline.RefineError` — pipeline-typed wrapping errors.
    /// 3. Everything else → `.io` (retryable fallback).
    public static func classify(_ error: Error) -> RefinementJobError {
        if let de = error as? Diarizer.DiarizeError {
            switch de {
            case .pythonNotFound, .launchFailed:
                return .missingDependency
            case .wavNotFound:
                return .transcribeFailed
            case .nonZeroExit, .timedOut, .emptyOutput, .decodeFailed:
                return .diarizeCrashed
            case .cancelled:
                // Should not reach here (ResumableRefiner retries internally),
                // but classify defensively as transient.
                return .diarizeCrashed
            }
        }

        // RefinementPipeline.RefineError wraps the underlying cause and
        // carries a coarse category. Map each branch to the closest queue
        // bucket. `.input` collapses to `.io` (no dedicated bucket); the
        // queue surfaces it as retryable because that matches the queue's
        // retry contract — the CLI's `RefineError.retryAvailable: false`
        // for `.input` is the CLI's own decision.
        if let re = error as? RefinementPipeline.RefineError {
            switch re {
            case .transcription: return .transcribeFailed
            case .diarization:   return .diarizeCrashed
            case .io, .input:    return .io
            }
        }

        // The queue's `ResumableRefiner.run` calls the in-process
        // `WhisperKitRegionTranscriber` directly and rethrows
        // `TranscriptionError` un-wrapped — i.e. it does not pass through
        // `RefinementPipeline.RefineError.transcription`. Without this
        // arm those failures collapsed to `.io`, hiding their true cause
        // in the `refinement_failed` event log. Every variant of
        // `TranscriptionError` is a transcription failure; the model-
        // load and not-found variants are still transient at the queue level
        // because a fresh `ensureLoaded` (the load slot is cleared on failure)
        // or re-fetch can recover them.
        if error is TranscriptionError {
            return .transcribeFailed
        }

        // Defensive fallback for a `CancellationError` that reaches `classify`
        // (D39 in-process). The recording-start cancel does NOT come through here:
        // `RefinementJobQueue` intercepts ANY `CancellationError` unconditionally
        // and requeues the same job with its checkpoint intact (no failure, no
        // `refinement_failed`). This arm is thus unreachable from the queue path,
        // but should a cancel ever surface here via some other caller, treat it
        // as a transient transcription failure — `retryAvailable: true` — the
        // same bucket the old subprocess-kill IPC-EOF mapped to
        // (`transcriptionFailed`).
        if error is CancellationError {
            return .transcribeFailed
        }

        return .io
    }
}
