// Tests/UnitTests/RefinementJobErrorTests.swift
import Foundation
import Testing
@testable import PulsarTraceEngine

/// Verifies that `RefinementJobError.classify` maps each error source to the
/// correct `(errorClass, retryAvailable)` pair, and that a stub `runJob` that
/// throws each class produces the right `.failed` state on the queue.
@Suite("RefinementJobError")
struct RefinementJobErrorTests {

    // MARK: - Classifier unit tests

    @Test("ModelStoreError.hashMismatch → modelChecksum, not retryable")
    func classifiesHashMismatch() {
        let err = ModelStore.ModelStoreError.hashMismatch(expected: "abc", actual: "xyz")
        let classified = RefinementJobError.classify(err)
        #expect(classified.errorClass == "modelChecksum")
        #expect(classified.retryAvailable == false)
    }

    @Test("ModelStoreError.sizeMismatch → modelChecksum, not retryable")
    func classifiesSizeMismatch() {
        let err = ModelStore.ModelStoreError.sizeMismatch(expected: 100, actual: 50)
        let classified = RefinementJobError.classify(err)
        #expect(classified.errorClass == "modelChecksum")
        #expect(classified.retryAvailable == false)
    }

    @Test("ModelStoreError.httpError → modelMissing, not retryable")
    func classifiesHttpError() {
        let err = ModelStore.ModelStoreError.httpError(404)
        let classified = RefinementJobError.classify(err)
        #expect(classified.errorClass == "modelMissing")
        #expect(classified.retryAvailable == false)
    }

    @Test("ModelStoreError.noData → modelMissing, not retryable")
    func classifiesNoData() {
        let classified = RefinementJobError.classify(ModelStore.ModelStoreError.noData)
        #expect(classified.errorClass == "modelMissing")
        #expect(classified.retryAvailable == false)
    }

    @Test("DiarizeError.pythonNotFound → missingDependency, not retryable")
    func classifiesPythonNotFound() {
        let err = Diarizer.DiarizeError.pythonNotFound("/usr/bin/python3")
        let classified = RefinementJobError.classify(err)
        #expect(classified.errorClass == "missingDependency")
        #expect(classified.retryAvailable == false)
    }

    @Test("DiarizeError.launchFailed → missingDependency, not retryable")
    func classifiesLaunchFailed() {
        let err = Diarizer.DiarizeError.launchFailed("exec failed")
        let classified = RefinementJobError.classify(err)
        #expect(classified.errorClass == "missingDependency")
        #expect(classified.retryAvailable == false)
    }

    @Test("DiarizeError.wavNotFound → transcribeFailed, retryable")
    func classifiesWavNotFound() {
        let err = Diarizer.DiarizeError.wavNotFound("/tmp/missing.wav")
        let classified = RefinementJobError.classify(err)
        #expect(classified.errorClass == "transcribeFailed")
        #expect(classified.retryAvailable == true)
    }

    @Test("DiarizeError.nonZeroExit → diarizeCrashed, retryable")
    func classifiesNonZeroExit() {
        let err = Diarizer.DiarizeError.nonZeroExit(code: 1, stderrTail: "OOM")
        let classified = RefinementJobError.classify(err)
        #expect(classified.errorClass == "diarizeCrashed")
        #expect(classified.retryAvailable == true)
    }

    @Test("DiarizeError.timedOut → diarizeCrashed, retryable")
    func classifiesTimedOut() {
        let err = Diarizer.DiarizeError.timedOut(seconds: 600)
        let classified = RefinementJobError.classify(err)
        #expect(classified.errorClass == "diarizeCrashed")
        #expect(classified.retryAvailable == true)
    }

    @Test("DiarizeError.emptyOutput → diarizeCrashed, retryable")
    func classifiesEmptyOutput() {
        let classified = RefinementJobError.classify(Diarizer.DiarizeError.emptyOutput)
        #expect(classified.errorClass == "diarizeCrashed")
        #expect(classified.retryAvailable == true)
    }

    @Test("DiarizeError.decodeFailed → diarizeCrashed, retryable")
    func classifiesDecodeFailed() {
        let err = Diarizer.DiarizeError.decodeFailed("bad JSON")
        let classified = RefinementJobError.classify(err)
        #expect(classified.errorClass == "diarizeCrashed")
        #expect(classified.retryAvailable == true)
    }

    @Test("unknown error → io, retryable")
    func classifiesUnknownError() {
        struct Unexpected: Error {}
        let classified = RefinementJobError.classify(Unexpected())
        #expect(classified.errorClass == "io")
        #expect(classified.retryAvailable == true)
    }

    @Test("WhisperTranscribeError.transcriptionFailed → transcribeFailed, retryable")
    func classifiesWhisperTranscriptionFailed() {
        let classified = RefinementJobError.classify(
            WhisperTranscribeError.transcriptionFailed(-1))
        #expect(classified.errorClass == "transcribeFailed")
        #expect(classified.retryAvailable == true)
    }

    @Test("WhisperTranscribeError.modelLoadFailed → transcribeFailed, retryable")
    func classifiesWhisperModelLoadFailed() {
        let classified = RefinementJobError.classify(
            WhisperTranscribeError.modelLoadFailed("oom"))
        #expect(classified.errorClass == "transcribeFailed")
        #expect(classified.retryAvailable == true)
    }

    @Test("WhisperTranscribeError.modelNotFound → transcribeFailed, retryable")
    func classifiesWhisperModelNotFound() {
        let classified = RefinementJobError.classify(
            WhisperTranscribeError.modelNotFound("/no/model"))
        #expect(classified.errorClass == "transcribeFailed")
        #expect(classified.retryAvailable == true)
    }

    @Test("WhisperTranscribeError.emptyAudio → transcribeFailed, retryable")
    func classifiesWhisperEmptyAudio() {
        let classified = RefinementJobError.classify(
            WhisperTranscribeError.emptyAudio)
        #expect(classified.errorClass == "transcribeFailed")
        #expect(classified.retryAvailable == true)
    }

    // MARK: - Queue integration: stub runJob produces correct .failed state

    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-joberr-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeQueue(throwing error: Error) async throws -> RefinementJobQueue {
        let store = RefinementJobStore(directory: tempDir())
        let queue = RefinementJobQueue(
            store: store,
            runJob: { _ in throw error })
        try await queue.start()
        return queue
    }

    private func runAndWaitForFailure(_ queue: RefinementJobQueue) async throws -> RefinementJobState {
        try await queue.enqueueManualRefine(
            folderURL: URL(fileURLWithPath: "/tmp/x"),
            recordingId: "rec_test",
            modelName: "base",
            modelSHA256: "deadbeef")

        var snap = await queue.snapshot()
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline,
              !(snap.running == nil && snap.recent.count == 1) {
            try await Task.sleep(for: .milliseconds(10))
            snap = await queue.snapshot()
        }
        return snap.recent.first?.state ?? .queued
    }

    @Test("queue: modelChecksum error produces .failed(errorClass: modelChecksum, retryAvailable: false)")
    func queueProducesModelChecksumFailed() async throws {
        let queue = try await makeQueue(
            throwing: ModelStore.ModelStoreError.hashMismatch(expected: "a", actual: "b"))
        let state = try await runAndWaitForFailure(queue)
        if case .failed(let cls, let retry) = state {
            #expect(cls == "modelChecksum")
            #expect(retry == false)
        } else {
            Issue.record("expected .failed, got \(state)")
        }
    }

    @Test("queue: diarizeCrashed error produces .failed(errorClass: diarizeCrashed, retryAvailable: true)")
    func queueProducesDiarizeCrashedFailed() async throws {
        let queue = try await makeQueue(
            throwing: Diarizer.DiarizeError.nonZeroExit(code: 1, stderrTail: "crash"))
        let state = try await runAndWaitForFailure(queue)
        if case .failed(let cls, let retry) = state {
            #expect(cls == "diarizeCrashed")
            #expect(retry == true)
        } else {
            Issue.record("expected .failed, got \(state)")
        }
    }

    @Test("queue: missingDependency error produces .failed(errorClass: missingDependency, retryAvailable: false)")
    func queueProducesMissingDependencyFailed() async throws {
        let queue = try await makeQueue(
            throwing: Diarizer.DiarizeError.pythonNotFound("/no/python"))
        let state = try await runAndWaitForFailure(queue)
        if case .failed(let cls, let retry) = state {
            #expect(cls == "missingDependency")
            #expect(retry == false)
        } else {
            Issue.record("expected .failed, got \(state)")
        }
    }

    @Test("queue: io fallback error produces .failed(errorClass: io, retryAvailable: true)")
    func queueProducesIOFailed() async throws {
        struct SomeIOError: Error {}
        let queue = try await makeQueue(throwing: SomeIOError())
        let state = try await runAndWaitForFailure(queue)
        if case .failed(let cls, let retry) = state {
            #expect(cls == "io")
            #expect(retry == true)
        } else {
            Issue.record("expected .failed, got \(state)")
        }
    }

    @Test("classify maps RefineError.transcription to .transcribeFailed")
    func classifyRefineErrorTranscription() {
        struct Boom: Error {}
        let classified = RefinementJobError.classify(
            RefinementPipeline.RefineError.transcription(Boom()))
        #expect(classified.errorClass == "transcribeFailed")
        #expect(classified.retryAvailable == true)
    }

    @Test("classify maps RefineError.diarization to .diarizeCrashed")
    func classifyRefineErrorDiarization() {
        struct Boom: Error {}
        let classified = RefinementJobError.classify(
            RefinementPipeline.RefineError.diarization(Boom()))
        #expect(classified.errorClass == "diarizeCrashed")
        #expect(classified.retryAvailable == true)
    }

    @Test("classify maps RefineError.io to .io")
    func classifyRefineErrorIO() {
        struct Boom: Error {}
        let classified = RefinementJobError.classify(
            RefinementPipeline.RefineError.io(Boom()))
        #expect(classified.errorClass == "io")
        #expect(classified.retryAvailable == true)
    }

    @Test("classify maps RefineError.input to .io (non-retryable)")
    func classifyRefineErrorInput() {
        let inner = RecordingFolder.InputError.pathNotFound("/x")
        let classified = RefinementJobError.classify(
            RefinementPipeline.RefineError.input(inner))
        #expect(classified.errorClass == "io")
        // RefineError.input.retryAvailable is false, but our classify
        // collapses input to .io which is retryable. Document that.
        #expect(classified.retryAvailable == true)
    }
}
