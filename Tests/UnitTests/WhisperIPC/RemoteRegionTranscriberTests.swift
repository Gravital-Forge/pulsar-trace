import Testing
import Foundation
import Logging
@testable import PulsarTraceEngine

/// Coverage of `RemoteRegionTranscriber`'s decode + watchdog state
/// machine via a fake `WhisperHostProtocol`. The real host is not
/// spawned here — those code paths are exercised by Phase 7.
///
/// Mirrors `RemoteWindowTranscriberTests` for the refinement path.
@Suite("RemoteRegionTranscriber")
struct RemoteRegionTranscriberTests {

    // MARK: - Happy path

    @Test("happy path: decode returns a TranscriptionResult with recording-absolute segment times")
    func happyPath() throws {
        let fake = FakeHost()
        // Subprocess sees only the region's slice (regionStartMs=0),
        // so its segment timestamps are region-relative. The client
        // shifts them by `region.start` to recover recording-absolute
        // times — same contract as the in-process
        // `WhisperTranscriber.transcribeRegion`.
        fake.cannedDecode = .decoded(WhisperIPCDecoded(
            requestId: UUID(),
            segments: [
                WhisperIPCSegment(text: "hello", startMs: 0, endMs: 1_500),
                WhisperIPCSegment(text: "world", startMs: 1_500, endMs: 3_000),
            ],
            language: "en"))
        let factory = SingleHostFactory(host: fake)

        let trans = makeTranscriber(factory: factory.factory)
        let region = SpeechRegion(start: .seconds(12), end: .seconds(15))
        let result = try trans.transcribeRegion(
            sixteenSeconds,
            region: region,
            options: WhisperOptions())

        #expect(result.language == "en")
        #expect(result.segments.count == 2)
        #expect(result.segments[0].text == "hello")
        #expect(result.segments[0].start == .seconds(12))
        #expect(result.segments[0].end == .milliseconds(13_500))
        #expect(result.segments[1].text == "world")
        #expect(result.segments[1].start == .milliseconds(13_500))
        #expect(result.segments[1].end == .seconds(15))
        #expect(fake.startCalls == 1)
        #expect(fake.decodeCalls == 1)
        // Lazy-init: only one host built so far.
        #expect(factory.callCount == 1)
    }

    @Test("subsequent decodes reuse the same host — no respawn on the steady path")
    func decodesReuseHost() throws {
        let fake = FakeHost()
        fake.cannedDecode = .decoded(WhisperIPCDecoded(
            requestId: UUID(),
            segments: [WhisperIPCSegment(text: "x", startMs: 0, endMs: 100)],
            language: "en"))
        let factory = SingleHostFactory(host: fake)
        let trans = makeTranscriber(factory: factory.factory)

        let region = SpeechRegion(start: .zero, end: .seconds(1))
        for _ in 0..<3 {
            _ = try trans.transcribeRegion(
                sixteenSeconds, region: region, options: WhisperOptions())
        }
        #expect(fake.startCalls == 1)
        #expect(fake.decodeCalls == 3)
        #expect(factory.callCount == 1)
    }

    // MARK: - Request shape

    @Test("transcribeRegion sends a decodeRegion request whose bounds match the slice (regionStartMs=0)")
    func sendsDecodeRegionRequest() throws {
        let fake = FakeHost()
        fake.cannedDecode = decodedResponse()
        let factory = SingleHostFactory(host: fake)
        let trans = makeTranscriber(factory: factory.factory)

        let region = SpeechRegion(
            start: .milliseconds(2_500),
            end: .milliseconds(7_750))
        _ = try trans.transcribeRegion(
            sixteenSeconds, region: region, options: WhisperOptions())

        let captured = fake.lastRequest
        guard case .decodeRegion(let payload) = captured else {
            Issue.record("expected a decodeRegion request, got: \(String(describing: captured))")
            return
        }
        // After client-side slicing the subprocess sees only the slice;
        // recording-absolute bounds are applied on the client when the
        // result comes back.
        #expect(payload.regionStartMs == 0)
        #expect(payload.regionEndMs == 5_250)
    }

    @Test("transcribeRegion only sends the region's samples in the IPC payload, not the entire recording")
    func sendsOnlyRegionSamples() throws {
        // 2026-05-28 incident: a ~99-minute recording sent the entire
        // 364 MB sample buffer in the IPC payload for *every* region
        // decode, because the client encoded `samples` (the whole
        // recording) instead of the region's slice. The subprocess's
        // IPC frame limit caught it as "frame payload exceeds maximum"
        // before any decode could complete. Fix: slice on the client
        // — payload size must scale with region duration, not
        // recording duration.
        let fake = FakeHost()
        fake.cannedDecode = .decoded(WhisperIPCDecoded(
            requestId: UUID(),
            segments: [],
            language: "en"))
        let factory = SingleHostFactory(host: fake)
        let trans = makeTranscriber(factory: factory.factory)

        // 2-second buffer at 16 kHz = 32_000 samples.
        let samples = [Float](repeating: 0.0, count: 32_000)
        // Region 1.0s → 1.5s = exactly 8_000 samples.
        let region = SpeechRegion(
            start: .milliseconds(1_000),
            end: .milliseconds(1_500))

        _ = try trans.transcribeRegion(
            samples, region: region, options: WhisperOptions())

        guard case .decodeRegion(let payload) = fake.lastRequest else {
            Issue.record("expected decodeRegion request")
            return
        }
        let decoded = try WhisperIPCSamples.decode(payload.samplesBase64)
        #expect(decoded.count == 8_000,
                "wire payload must contain only the region's samples; got \(decoded.count) of \(samples.count)")
        // After client-side slicing, the subprocess only ever sees a
        // [0..sliceDuration) region — recording-absolute bounds are
        // applied on the client.
        #expect(payload.regionStartMs == 0)
        #expect(payload.regionEndMs == 500)
    }

    @Test("region-relative segment times from the subprocess are shifted to recording-absolute on the client")
    func shiftsSegmentTimesToRecordingAbsolute() throws {
        // After client-side slicing, the subprocess sees regionStartMs=0
        // (it only knows about the slice). Its segment timestamps are
        // therefore region-relative. The client must shift by the
        // original region.start so callers see recording-absolute
        // times — same contract as the in-process
        // WhisperTranscriber.transcribeRegion.
        let fake = FakeHost()
        fake.cannedDecode = .decoded(WhisperIPCDecoded(
            requestId: UUID(),
            segments: [
                WhisperIPCSegment(text: "hello", startMs: 100, endMs: 200),
            ],
            language: "en"))
        let factory = SingleHostFactory(host: fake)
        let trans = makeTranscriber(factory: factory.factory)

        let samples = [Float](repeating: 0, count: 32_000)
        let region = SpeechRegion(
            start: .seconds(1),
            end: .milliseconds(1_500))
        let result = try trans.transcribeRegion(
            samples, region: region, options: WhisperOptions())

        #expect(result.segments.count == 1)
        #expect(result.segments[0].start == .milliseconds(1_100))
        #expect(result.segments[0].end == .milliseconds(1_200))
    }

    // MARK: - Empty audio

    @Test("empty samples throw emptyAudio without spawning a host")
    func emptyAudioShortCircuits() {
        let fake = FakeHost()
        let factory = SingleHostFactory(host: fake)
        let trans = makeTranscriber(factory: factory.factory)

        do {
            _ = try trans.transcribeRegion(
                [], region: SpeechRegion(start: .zero, end: .seconds(1)),
                options: WhisperOptions())
            Issue.record("expected throw")
        } catch WhisperTranscribeError.emptyAudio {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(factory.callCount == 0)
    }

    // MARK: - Deadline + respawn

    @Test("readTimedOut: host SIGKILL'd, fresh host spawned, wedged region surfaced as transcriptionFailed")
    func deadlineTriggersRespawn() throws {
        let wedged = FakeHost()
        wedged.cannedDecodeError = .readTimedOut

        let fresh = FakeHost()
        fresh.cannedDecode = .decoded(WhisperIPCDecoded(
            requestId: UUID(),
            segments: [WhisperIPCSegment(text: "recovered", startMs: 5_000, endMs: 6_000)],
            language: "en"))

        let factory = SequencedHostFactory(hosts: [wedged, fresh])
        let trans = makeTranscriber(
            factory: factory.factory,
            logBackoffInitial: .milliseconds(10))

        let region = SpeechRegion(start: .seconds(1), end: .seconds(5))
        // First decode: hits the wedge → SIGKILL + respawn + throws
        // transcriptionFailed for this region. ResumableRefiner upstream
        // will surface this throw and resume from the previous
        // checkpoint on the next attempt.
        do {
            _ = try trans.transcribeRegion(
                sixteenSeconds, region: region, options: WhisperOptions())
            Issue.record("expected throw")
        } catch WhisperTranscribeError.transcriptionFailed(let code) {
            #expect(code == -1)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(wedged.sigkillCalls == 1)
        #expect(factory.callCount == 2)

        // Second decode (the "retry" in ResumableRefiner's flow)
        // succeeds on the fresh host.
        let result = try trans.transcribeRegion(
            sixteenSeconds, region: region, options: WhisperOptions())
        #expect(result.segments.first?.text == "recovered")
        #expect(fresh.decodeCalls == 1)
    }

    @Test("readTimedOut: emits the 'region decode exceeded deadline' warning so log-greps disambiguate refinement from live")
    func deadlineLogsRegionMessage() throws {
        let wedged = FakeHost()
        wedged.cannedDecodeError = .readTimedOut
        let fresh = FakeHost()
        fresh.cannedDecode = decodedResponse()
        let factory = SequencedHostFactory(hosts: [wedged, fresh])
        let capture = CapturingLogHandler()
        let trans = makeTranscriber(
            factory: factory.factory,
            logger: Logger(label: "test") { _ in capture },
            logBackoffInitial: .milliseconds(10))

        _ = try? trans.transcribeRegion(
            sixteenSeconds,
            region: SpeechRegion(start: .seconds(1), end: .seconds(5)),
            options: WhisperOptions())

        let exceeded = capture.messages.filter {
            $0.contains("whisper region decode exceeded deadline")
        }
        #expect(exceeded.count == 1, "saw: \(capture.messages)")
    }

    @Test("subprocessGone during decode is treated as a recoverable wedge")
    func subprocessGoneTriggersRespawn() throws {
        let wedged = FakeHost()
        wedged.cannedDecodeError = .subprocessGone(exitStatus: 1)

        let fresh = FakeHost()
        fresh.cannedDecode = decodedResponse()

        let factory = SequencedHostFactory(hosts: [wedged, fresh])
        let trans = makeTranscriber(
            factory: factory.factory,
            logBackoffInitial: .milliseconds(10))

        do {
            _ = try trans.transcribeRegion(
                sixteenSeconds,
                region: SpeechRegion(start: .zero, end: .seconds(2)),
                options: WhisperOptions())
            Issue.record("expected throw")
        } catch WhisperTranscribeError.transcriptionFailed(let code) {
            #expect(code == -1)
        } catch {
            Issue.record("unexpected: \(error)")
        }
        #expect(wedged.sigkillCalls == 1)
        #expect(factory.callCount == 2)
    }

    @Test(
        "respawn that takes longer than the initial backoff emits at least one 'still waiting' log line",
        .disabled("flaky under parallel UnitTests pool starvation; verify with --filter RemoteRegionTranscriber")
    )
    func backoffLogFires() async throws {
        let wedged = FakeHost()
        wedged.cannedDecodeError = .readTimedOut
        // Slow host: artificially delay `startAndInitialize` past the
        // first backoff interval so the throttled log fires at least
        // once before the respawn completes.
        //
        // Margins match the window-variant tests: 30ms backoff / 500ms
        // slow-start = ~470ms slack, plenty for the global pool to
        // schedule + sleep + log even when 50+ other suites run
        // concurrently.
        let slow = FakeHost()
        slow.startDelay = .milliseconds(500)
        slow.cannedDecode = decodedResponse()

        let factory = SequencedHostFactory(hosts: [wedged, slow])
        let capture = CapturingLogHandler()
        let trans = makeTranscriber(
            factory: factory.factory,
            logger: Logger(label: "test") { _ in capture },
            logBackoffInitial: .milliseconds(30))

        _ = try? trans.transcribeRegion(
            sixteenSeconds,
            region: SpeechRegion(start: .seconds(1), end: .seconds(5)),
            options: WhisperOptions())

        let waiting = capture.messages.filter {
            $0.contains("still waiting for whisper subprocess respawn")
        }
        #expect(waiting.count >= 1,
                "expected backoff log; saw: \(capture.messages)")
    }

    // MARK: - Subprocess-reported error

    @Test(".error response from subprocess surfaces as a WhisperTranscribeError matching the kind")
    func subprocessErrorSurfaced() throws {
        let fake = FakeHost()
        fake.cannedDecode = .error(WhisperIPCError(
            requestId: UUID(),
            kind: "transcription_failed",
            message: "whisper_full returned -1"))
        let factory = SingleHostFactory(host: fake)
        let trans = makeTranscriber(factory: factory.factory)

        do {
            _ = try trans.transcribeRegion(
                sixteenSeconds,
                region: SpeechRegion(start: .seconds(1), end: .seconds(5)),
                options: WhisperOptions())
            Issue.record("expected throw")
        } catch WhisperTranscribeError.transcriptionFailed {
            // expected
        } catch {
            Issue.record("unexpected: \(error)")
        }
        // No respawn — the subprocess is still healthy, the *region*
        // failed decode.
        #expect(fake.sigkillCalls == 0)
        #expect(factory.callCount == 1)
    }

    @Test(".error with an unknown kind logs kind+message before collapsing to transcriptionFailed(-1)")
    func subprocessUnknownErrorLogsPayload() throws {
        let fake = FakeHost()
        fake.cannedDecode = .error(WhisperIPCError(
            requestId: UUID(),
            kind: "decode_internal",
            message: "samples decode failed: bad base64"))
        let factory = SingleHostFactory(host: fake)
        let capture = CapturingLogHandler()
        let trans = makeTranscriber(
            factory: factory.factory,
            logger: Logger(label: "test") { _ in capture })

        do {
            _ = try trans.transcribeRegion(
                sixteenSeconds,
                region: SpeechRegion(start: .seconds(1), end: .seconds(5)),
                options: WhisperOptions())
            Issue.record("expected throw")
        } catch WhisperTranscribeError.transcriptionFailed {
            // expected
        } catch {
            Issue.record("unexpected: \(error)")
        }
        let payloadMatches = capture.messages.filter {
            $0.contains("decode_internal") && $0.contains("bad base64")
        }
        #expect(payloadMatches.count >= 1,
                "expected subprocess error kind/message to be logged; saw: \(capture.messages)")
    }

    @Test(".error with kind=model_not_found maps to WhisperTranscribeError.modelNotFound")
    func subprocessModelNotFoundMapped() throws {
        let fake = FakeHost()
        fake.cannedDecode = .error(WhisperIPCError(
            requestId: UUID(),
            kind: "model_not_found",
            message: "no model"))
        let factory = SingleHostFactory(host: fake)
        let trans = makeTranscriber(factory: factory.factory)

        do {
            _ = try trans.transcribeRegion(
                sixteenSeconds,
                region: SpeechRegion(start: .seconds(1), end: .seconds(5)),
                options: WhisperOptions())
            Issue.record("expected throw")
        } catch WhisperTranscribeError.modelNotFound {
            // expected
        } catch {
            Issue.record("unexpected: \(error)")
        }
    }

    @Test(".error with kind=empty_audio maps to WhisperTranscribeError.emptyAudio")
    func subprocessEmptyAudioMapped() throws {
        let fake = FakeHost()
        fake.cannedDecode = .error(WhisperIPCError(
            requestId: UUID(),
            kind: "empty_audio",
            message: "no samples"))
        let factory = SingleHostFactory(host: fake)
        let trans = makeTranscriber(factory: factory.factory)

        do {
            _ = try trans.transcribeRegion(
                sixteenSeconds,
                region: SpeechRegion(start: .seconds(1), end: .seconds(5)),
                options: WhisperOptions())
            Issue.record("expected throw")
        } catch WhisperTranscribeError.emptyAudio {
            // expected
        } catch {
            Issue.record("unexpected: \(error)")
        }
    }

    // MARK: - Non-recoverable spawn failure

    @Test("first start fails with .binaryNotFound — surfaced as modelLoadFailed")
    func startBinaryNotFound() {
        let factory = SequencedHostFactory(
            hosts: [],
            startErrors: [.binaryNotFound("/nope")])
        let trans = makeTranscriber(factory: factory.factory)

        do {
            _ = try trans.transcribeRegion(
                sixteenSeconds,
                region: SpeechRegion(start: .zero, end: .seconds(1)),
                options: WhisperOptions())
            Issue.record("expected throw")
        } catch WhisperTranscribeError.modelLoadFailed(let message) {
            #expect(message.contains("/nope"))
        } catch {
            Issue.record("unexpected: \(error)")
        }
    }

    @Test("handleHostError log identifies the specific HostError variant, not 'exceeded deadline' for all 4 cases")
    func handleHostErrorLogIdentifiesVariant() throws {
        // The 2026-05-27 incident: subprocess died ~12s into the first
        // region decode. The 120s `decodeDeadline` was nowhere near
        // expiring — but the warning said "exceeded deadline" because
        // the message was hardcoded for *every* HostError variant. The
        // fix interpolates the variant (subprocessGone / readEOF /
        // writeFailed / readTimedOut), so post-mortem reading the log
        // tells you whether it was a true timeout vs a subprocess
        // crash.
        let wedged = FakeHost()
        wedged.cannedDecodeError = .subprocessGone(exitStatus: 134)
        let fresh = FakeHost()
        fresh.cannedDecode = decodedResponse()
        let factory = SequencedHostFactory(hosts: [wedged, fresh])
        let capture = CapturingLogHandler()
        let trans = makeTranscriber(
            factory: factory.factory,
            logger: Logger(label: "test") { _ in capture },
            logBackoffInitial: .milliseconds(10))

        _ = try? trans.transcribeRegion(
            sixteenSeconds,
            region: SpeechRegion(start: .seconds(1), end: .seconds(5)),
            options: WhisperOptions())

        let variantMatches = capture.messages.filter {
            $0.contains("killing subprocess for respawn")
                && ($0.contains("subprocessGone") || $0.contains("exited (status=134)"))
        }
        #expect(variantMatches.count >= 1,
                "expected HostError variant in warning; saw: \(capture.messages)")
    }

    @Test("respawn that fails to start the replacement host logs the spawn error before rethrowing")
    func respawnFailureLogsSpawnError() throws {
        let wedged = FakeHost()
        wedged.cannedDecodeError = .readTimedOut

        let factory = SequencedHostFactory(
            hosts: [wedged],
            // Second factory call (the respawn) throws.
            startErrors: [nil, .binaryNotFound("/gone")])
        let capture = CapturingLogHandler()
        let trans = makeTranscriber(
            factory: factory.factory,
            logger: Logger(label: "test") { _ in capture },
            logBackoffInitial: .milliseconds(10))

        _ = try? trans.transcribeRegion(
            sixteenSeconds,
            region: SpeechRegion(start: .seconds(1), end: .seconds(5)),
            options: WhisperOptions())

        let respawnFailure = capture.messages.filter {
            $0.contains("whisper subprocess respawn failed")
                && $0.contains("/gone")
        }
        #expect(respawnFailure.count >= 1,
                "expected respawn-failure log; saw: \(capture.messages)")
    }

    @Test("respawn fails with .binaryNotFound — surfaced as modelLoadFailed on the wedged region")
    func respawnFailureSurfacesModelLoadFailed() throws {
        let wedged = FakeHost()
        wedged.cannedDecodeError = .readTimedOut

        let factory = SequencedHostFactory(
            hosts: [wedged],
            // Second factory call (the respawn) throws.
            startErrors: [nil, .binaryNotFound("/gone")])
        let trans = makeTranscriber(
            factory: factory.factory,
            logBackoffInitial: .milliseconds(10))

        do {
            _ = try trans.transcribeRegion(
                sixteenSeconds,
                region: SpeechRegion(start: .seconds(1), end: .seconds(5)),
                options: WhisperOptions())
            Issue.record("expected throw")
        } catch WhisperTranscribeError.modelLoadFailed(let m) {
            #expect(m.contains("/gone"))
        } catch {
            Issue.record("unexpected: \(error)")
        }
        #expect(wedged.sigkillCalls == 1)
    }

    @Test("first start with .initRefused surfaces as modelLoadFailed")
    func initRefusedNonRecoverable() {
        let factory = SequencedHostFactory(
            hosts: [],
            startErrors: [.initRefused("model corrupt")])
        let trans = makeTranscriber(factory: factory.factory)
        do {
            _ = try trans.transcribeRegion(
                sixteenSeconds,
                region: SpeechRegion(start: .zero, end: .seconds(1)),
                options: WhisperOptions())
            Issue.record("expected throw")
        } catch WhisperTranscribeError.modelLoadFailed(let m) {
            #expect(m.contains("model corrupt"))
        } catch {
            Issue.record("unexpected: \(error)")
        }
    }

    // MARK: - Shutdown

    @Test("shutdown: terminates the host cooperatively")
    func shutdownTerminatesHost() throws {
        let fake = FakeHost()
        fake.cannedDecode = decodedResponse()
        let factory = SingleHostFactory(host: fake)
        let trans = makeTranscriber(factory: factory.factory)

        _ = try trans.transcribeRegion(
            sixteenSeconds,
            region: SpeechRegion(start: .zero, end: .seconds(1)),
            options: WhisperOptions())

        trans.shutdown()
        #expect(fake.terminateCalls == 1)
        // Idempotent: a second shutdown is a no-op.
        trans.shutdown()
        #expect(fake.terminateCalls == 1)
    }
}

// MARK: - Test fixtures

private func makeTranscriber(
    factory: @escaping RemoteRegionTranscriber.HostFactory,
    logger: Logger = Logger(label: "test"),
    logBackoffInitial: Duration = .milliseconds(5)
) -> RemoteRegionTranscriber {
    let config = RemoteRegionTranscriber.Configuration(
        binaryURL: URL(fileURLWithPath: "/tmp/fake-whisper"),
        modelURL: URL(fileURLWithPath: "/tmp/model.bin"),
        socketDirectory: URL(
            fileURLWithPath: NSTemporaryDirectory(),
            isDirectory: true),
        decodeDeadline: .milliseconds(50),
        respawnDeadline: .seconds(2),
        logBackoffInitial: logBackoffInitial,
        logBackoffCap: .milliseconds(100))
    return RemoteRegionTranscriber(
        configuration: config,
        logger: logger,
        hostFactory: factory)
}

/// 16 seconds of silence (256_000 samples at 16 kHz) — big enough to
/// cover every region used by the tests in this file after the
/// client-side slicing fix landed. Without this, tests that pass
/// `[0.1]` with multi-second regions short-circuit to an empty
/// `TranscriptionResult` before ever touching the IPC layer.
private let sixteenSeconds: [Float] = [Float](repeating: 0, count: 256_000)
