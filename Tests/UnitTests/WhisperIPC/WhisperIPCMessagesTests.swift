import Testing
import Foundation
@testable import PulsarTraceEngine

/// Codable round-trip coverage for the request/response/options types the
/// `pulsartrace-whisper` channel speaks
/// (`docs/specs/2026-05-26-whisper-subprocess-design.md` §5).
@Suite("WhisperIPCMessages")
struct WhisperIPCMessagesTests {

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private let decoder = JSONDecoder()

    // MARK: - Requests

    @Test("init request round-trips and uses the \"init\" type tag")
    func initRequestRoundTrip() throws {
        let req = WhisperIPCRequest.initSession(model: "/tmp/base.bin", gpu: true)
        let data = try encoder.encode(req)
        let json = try jsonObject(data)
        #expect(json["type"] as? String == "init")
        #expect(json["model"] as? String == "/tmp/base.bin")
        #expect(json["gpu"] as? Bool == true)
        let decoded = try decoder.decode(WhisperIPCRequest.self, from: data)
        #expect(decoded == req)
    }

    @Test("decode_window request round-trips with the expected discriminator")
    func decodeWindowRequestRoundTrip() throws {
        let payload = WhisperIPCDecodeWindow(
            requestId: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            samplesBase64: "AAAA",
            windowStartMs: 12_345,
            options: WhisperIPCOptions())
        let req = WhisperIPCRequest.decodeWindow(payload)
        let data = try encoder.encode(req)
        let json = try jsonObject(data)
        #expect(json["type"] as? String == "decode_window")
        let decoded = try decoder.decode(WhisperIPCRequest.self, from: data)
        #expect(decoded == req)
    }

    @Test("decode_region request round-trips with the expected discriminator")
    func decodeRegionRequestRoundTrip() throws {
        let payload = WhisperIPCDecodeRegion(
            requestId: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            samplesBase64: "AAAA",
            regionStartMs: 1_000,
            regionEndMs: 2_500,
            options: WhisperIPCOptions(language: "en"))
        let req = WhisperIPCRequest.decodeRegion(payload)
        let data = try encoder.encode(req)
        let json = try jsonObject(data)
        #expect(json["type"] as? String == "decode_region")
        let decoded = try decoder.decode(WhisperIPCRequest.self, from: data)
        #expect(decoded == req)
    }

    @Test("shutdown request round-trips as a bare type tag")
    func shutdownRequestRoundTrip() throws {
        let req = WhisperIPCRequest.shutdown
        let data = try encoder.encode(req)
        let json = try jsonObject(data)
        #expect(json["type"] as? String == "shutdown")
        let decoded = try decoder.decode(WhisperIPCRequest.self, from: data)
        #expect(decoded == req)
    }

    // MARK: - Responses

    @Test("ready response round-trips with model_load_ms")
    func readyResponseRoundTrip() throws {
        let response = WhisperIPCResponse.ready(modelLoadMs: 1_234)
        let data = try encoder.encode(response)
        let json = try jsonObject(data)
        #expect(json["type"] as? String == "ready")
        #expect(json["model_load_ms"] as? Int == 1_234)
        let decoded = try decoder.decode(WhisperIPCResponse.self, from: data)
        #expect(decoded == response)
    }

    @Test("decoded response round-trips segments and language")
    func decodedResponseRoundTrip() throws {
        let payload = WhisperIPCDecoded(
            requestId: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            segments: [
                WhisperIPCSegment(text: "hello", startMs: 0, endMs: 500),
                WhisperIPCSegment(text: "world", startMs: 500, endMs: 1_000),
            ],
            language: "en")
        let response = WhisperIPCResponse.decoded(payload)
        let data = try encoder.encode(response)
        let json = try jsonObject(data)
        #expect(json["type"] as? String == "decoded")
        let decoded = try decoder.decode(WhisperIPCResponse.self, from: data)
        #expect(decoded == response)
    }

    @Test("error response round-trips with request_id, kind, message")
    func errorResponseRoundTrip() throws {
        let payload = WhisperIPCError(
            requestId: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
            kind: "transcription_failed",
            message: "whisper_full failed with code 7")
        let response = WhisperIPCResponse.error(payload)
        let data = try encoder.encode(response)
        let json = try jsonObject(data)
        #expect(json["type"] as? String == "error")
        let decoded = try decoder.decode(WhisperIPCResponse.self, from: data)
        #expect(decoded == response)
    }

    @Test("error response allows a null request_id for session-scope failures")
    func errorResponseNoRequestId() throws {
        let response = WhisperIPCResponse.error(
            WhisperIPCError(kind: "model_load_failed", message: "boom"))
        let data = try encoder.encode(response)
        let decoded = try decoder.decode(WhisperIPCResponse.self, from: data)
        #expect(decoded == response)
    }

    // MARK: - WhisperIPCError mapping

    @Test("WhisperIPCError maps every WhisperTranscribeError kind")
    func errorMapping() {
        let cases: [(WhisperTranscribeError, String)] = [
            (.modelNotFound("/x"), "model_not_found"),
            (.modelLoadFailed("/x"), "model_load_failed"),
            (.transcriptionFailed(-1), "transcription_failed"),
            (.emptyAudio, "empty_audio"),
        ]
        for (input, expectedKind) in cases {
            let err = WhisperIPCError(from: input)
            #expect(err.kind == expectedKind)
            #expect(err.requestId == nil)
            #expect(err.message == input.description)
        }
    }

    // MARK: - WhisperIPCOptions

    @Test("Options ↔ WhisperOptions round-trip preserves every field")
    func optionsRoundTrip() {
        let original = WhisperOptions(
            language: "es",
            threadCount: 4,
            noSpeechThreshold: 0.55,
            temperature: 0.3,
            temperatureFallbackStep: 0.15,
            vadModelURL: URL(fileURLWithPath: "/tmp/ggml-silero.bin"))
        let ipc = WhisperIPCOptions(from: original)
        #expect(ipc.language == "es")
        #expect(ipc.threadCount == 4)
        #expect(ipc.noSpeechThreshold == 0.55)
        #expect(ipc.temperature == 0.3)
        #expect(ipc.temperatureFallbackStep == 0.15)
        #expect(ipc.vadModelPath == "/tmp/ggml-silero.bin")

        let back = ipc.toWhisperOptions()
        #expect(back.language == original.language)
        #expect(back.threadCount == original.threadCount)
        #expect(back.noSpeechThreshold == original.noSpeechThreshold)
        #expect(back.temperature == original.temperature)
        #expect(back.temperatureFallbackStep == original.temperatureFallbackStep)
        #expect(back.vadModelURL?.path == "/tmp/ggml-silero.bin")
    }

    @Test("Options JSON uses snake_case wire keys")
    func optionsJSONKeys() throws {
        let opts = WhisperIPCOptions(
            language: "en",
            threadCount: 2,
            noSpeechThreshold: 0.6,
            temperature: 0.2,
            temperatureFallbackStep: 0.2,
            vadModelPath: "/tmp/vad")
        let data = try encoder.encode(opts)
        let json = try jsonObject(data)
        #expect(json["language"] as? String == "en")
        #expect(json["thread_count"] as? Int == 2)
        #expect((json["no_speech_threshold"] as? NSNumber)?.floatValue == 0.6)
        #expect((json["temperature"] as? NSNumber)?.floatValue == 0.2)
        #expect((json["temperature_fallback_step"] as? NSNumber)?.floatValue == 0.2)
        #expect(json["vad_model_path"] as? String == "/tmp/vad")
    }

    @Test("Options round-trips nil vadModelPath")
    func optionsNilVAD() throws {
        let opts = WhisperIPCOptions()
        let data = try encoder.encode(opts)
        let decoded = try decoder.decode(WhisperIPCOptions.self, from: data)
        #expect(decoded == opts)
        #expect(decoded.vadModelPath == nil)
    }

    // MARK: - WhisperIPCSamples

    @Test("Samples encode + decode round-trip a known buffer")
    func samplesRoundTrip() throws {
        let original: [Float] = [0.0, 0.5, -0.5, 1.0, -1.0, 0.123456]
        let encoded = WhisperIPCSamples.encode(original)
        // Base64 of `original.count * 4` bytes; sanity-check it parses.
        #expect(Data(base64Encoded: encoded) != nil)
        let decoded = try WhisperIPCSamples.decode(encoded)
        #expect(decoded == original)
    }

    @Test("Samples decode is empty for an empty buffer")
    func samplesEmpty() throws {
        let encoded = WhisperIPCSamples.encode([])
        let decoded = try WhisperIPCSamples.decode(encoded)
        #expect(decoded.isEmpty)
    }

    @Test("Samples decode rejects invalid base64")
    func samplesInvalidBase64() {
        #expect(throws: WhisperIPCSamples.SampleError.invalidBase64) {
            _ = try WhisperIPCSamples.decode("not!valid!base64!!")
        }
    }

    @Test("Samples decode rejects a non-Float-aligned byte count")
    func samplesMisaligned() {
        // 3 bytes of base64 → 3 raw bytes (not /4).
        let bytes = Data([0xAA, 0xBB, 0xCC])
        let b64 = bytes.base64EncodedString()
        #expect(throws: WhisperIPCSamples.SampleError.payloadNotFloatAligned(3)) {
            _ = try WhisperIPCSamples.decode(b64)
        }
    }

    // MARK: - Decoding-failure surface

    @Test("Request decode rejects an unknown type tag with a descriptive error")
    func unknownRequestType() throws {
        let json = Data(#"{"type":"do_a_barrel_roll"}"#.utf8)
        do {
            _ = try decoder.decode(WhisperIPCRequest.self, from: json)
            Issue.record("expected decode to throw on unknown discriminator")
        } catch let DecodingError.dataCorrupted(ctx) {
            // The descriptive error names the offending value on the wire
            // so a parent log line reading "unknown … type: …" is
            // immediately actionable.
            #expect(ctx.debugDescription.contains("do_a_barrel_roll"))
            #expect(ctx.debugDescription.localizedCaseInsensitiveContains("request"))
        } catch {
            Issue.record("expected DecodingError.dataCorrupted, got \(error)")
        }
    }

    @Test("Response decode rejects an unknown type tag with a descriptive error")
    func unknownResponseType() throws {
        let json = Data(#"{"type":"sideways"}"#.utf8)
        do {
            _ = try decoder.decode(WhisperIPCResponse.self, from: json)
            Issue.record("expected decode to throw on unknown discriminator")
        } catch let DecodingError.dataCorrupted(ctx) {
            #expect(ctx.debugDescription.contains("sideways"))
            #expect(ctx.debugDescription.localizedCaseInsensitiveContains("response"))
        } catch {
            Issue.record("expected DecodingError.dataCorrupted, got \(error)")
        }
    }

    // MARK: - Helpers

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        let raw = try JSONSerialization.jsonObject(with: data)
        return raw as? [String: Any] ?? [:]
    }
}
