// Sources/PulsarTraceEngine/Refinement/Jobs/RefinementJobError.swift
import Foundation

/// Classifies errors that propagate from `_runJob` into stable, UI-safe
/// identifiers. Drives the `errorClass` and `retryAvailable` fields of
/// `RefinementJobState.failed`.
///
/// Error sources surveyed (via `makeStandard`'s `runJob` closure):
/// - `ModelStore.ensureAvailable` → `ModelStore.ModelStoreError`
/// - `OfflineRefiner.makeDiarizer` → `Diarizer.DiarizeError` (.pythonNotFound,
///   .launchFailed)
/// - `ResumableRefiner.run` → `Diarizer.DiarizeError` (non-.cancelled variants),
///   raw `WhisperTranscriber.TranscribeError`, I/O errors from `WAVReader` /
///   `AtomicFile`.
/// - `RefinementPipeline.assembleAndWrite` → `RefinementPipeline.RefineError`
///   (when the assemble step's reconciler / file writes wrap into the typed
///   RefineError). Each `RefineError` branch maps to a queue bucket.
///
/// CancellationError note: `ResumableRefiner.run` does NOT propagate
/// `CancellationError` through Swift structured concurrency. The pause gate
/// (`PauseGate.waitOpen`) is a custom actor-based waiter, not `Task.sleep` or
/// `withTaskCancellationHandler`, so Swift task cancellation cannot interrupt it.
/// The diarizer's `.cancelled` case is caught internally and retried when the
/// gate reopens — it never surfaces to the queue's catch block as a throw.
/// Therefore no special `CancellationError` handling is needed here.
public enum RefinementJobError: Error {

    // MARK: - Stable error identifiers

    /// The whisper model file is not on disk and could not be downloaded.
    /// Permanent until the user re-initiates a download. `retryAvailable: false`.
    case modelMissing

    /// The model file's SHA-256 digest did not match the pinned hash.
    /// Indicates a corrupt or replaced file. `retryAvailable: false`.
    case modelChecksum

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
        case .modelMissing:      return "modelMissing"
        case .modelChecksum:     return "modelChecksum"
        case .diarizeCrashed:   return "diarizeCrashed"
        case .transcribeFailed: return "transcribeFailed"
        case .missingDependency: return "missingDependency"
        case .io:               return "io"
        }
    }

    /// `true` for transient failures the user can retry; `false` for permanent ones.
    public var retryAvailable: Bool {
        switch self {
        case .modelMissing:      return false
        case .modelChecksum:     return false
        case .diarizeCrashed:   return true
        case .transcribeFailed: return true
        case .missingDependency: return false
        case .io:               return true
        }
    }

    // MARK: - Classifier

    /// Map any thrown `Error` to a `RefinementJobError`.
    ///
    /// Priority:
    /// 1. `ModelStore.ModelStoreError` — download / checksum failures.
    /// 2. `Diarizer.DiarizeError` — subprocess-level failures.
    /// 3. Everything else → `.io` (retryable fallback).
    public static func classify(_ error: Error) -> RefinementJobError {
        if let ms = error as? ModelStore.ModelStoreError {
            switch ms {
            case .hashMismatch, .sizeMismatch:
                return .modelChecksum
            case .httpError, .noData:
                return .modelMissing
            }
        }

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

        return .io
    }
}
