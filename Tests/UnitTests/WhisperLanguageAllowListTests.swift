import Testing
import Foundation
@testable import PulsarTraceEngine

/// Pure-logic coverage of `WhisperTranscriber.pickAllowedLanguage` — the
/// argmax-over-allowed-subset used by the per-window pre-detect path when the
/// user has restricted the live pass to a language allow list (e.g.
/// `["en", "pl"]`). The real call site looks up language ids via
/// `whisper_lang_id`; here we stub it so the tests run without a whisper
/// context.
@Suite("Whisper language allow-list")
struct WhisperLanguageAllowListTests {

    /// Realistic whisper-style id lookup: a small dictionary mapping
    /// ISO-639-1 codes to fixed positions in the probabilities array.
    /// Unknown codes return `nil`, matching the real `whisper_lang_id`
    /// contract (it returns `-1` for unknown).
    private static let ids: [String: Int] = [
        "en": 0, "pl": 1, "fr": 2, "de": 3, "es": 4, "nn": 5, "ja": 6,
    ]
    private func id(for code: String) -> Int? { Self.ids[code] }

    @Test("argmax over the allowed subset returns the highest-prob allowed code")
    func picksHighestProbAllowed() {
        // English wins despite Polish being the **global** max because Polish
        // is in the allowed set too and has the higher allowed probability.
        let probs: [Float] = [0.40, 0.55, 0.01, 0.01, 0.01, 0.01, 0.01]
        let picked = WhisperTranscriber.pickAllowedLanguage(
            probs: probs, allowed: ["en", "pl"], idForCode: id(for:))
        #expect(picked == "pl")
    }

    @Test("an out-of-allow-list global max is ignored")
    func ignoresGlobalMaxOutsideAllowSet() {
        // Norwegian Nynorsk dominates — exactly the 740-window misfire shape
        // the user observed. The allow list `["en", "pl"]` must pick `en`
        // because en's probability (0.10) beats pl's (0.05), regardless of nn.
        let probs: [Float] = [0.10, 0.05, 0.01, 0.01, 0.01, 0.80, 0.02]
        let picked = WhisperTranscriber.pickAllowedLanguage(
            probs: probs, allowed: ["en", "pl"], idForCode: id(for:))
        #expect(picked == "en")
    }

    @Test("empty allow list returns nil — caller falls back to auto")
    func emptyAllowListReturnsNil() {
        let probs: [Float] = [0.5, 0.5, 0, 0, 0, 0, 0]
        let picked = WhisperTranscriber.pickAllowedLanguage(
            probs: probs, allowed: [], idForCode: id(for:))
        #expect(picked == nil)
    }

    @Test("unknown allowed codes are dropped, valid ones still resolve")
    func unknownCodesDropped() {
        let probs: [Float] = [0.30, 0.50, 0.01, 0.01, 0.01, 0.01, 0.01]
        // `xx` is unknown (returns nil from the stub); `pl` still picks.
        let picked = WhisperTranscriber.pickAllowedLanguage(
            probs: probs, allowed: ["xx", "pl"], idForCode: id(for:))
        #expect(picked == "pl")
    }

    @Test("all allowed codes unknown → nil")
    func allUnknownReturnsNil() {
        let probs: [Float] = [0.5, 0.5, 0, 0, 0, 0, 0]
        let picked = WhisperTranscriber.pickAllowedLanguage(
            probs: probs, allowed: ["xx", "yy"], idForCode: id(for:))
        #expect(picked == nil)
    }

    @Test("single allowed code wins even if its probability is tiny")
    func singleAllowedAlwaysWins() {
        // The user can effectively pin language by picking one allowed code.
        // We must not "fall back to auto" just because the probability is low —
        // that defeats the allow-list contract.
        let probs: [Float] = [0.001, 0.0, 0.99, 0.0, 0.0, 0.0, 0.0]
        let picked = WhisperTranscriber.pickAllowedLanguage(
            probs: probs, allowed: ["en"], idForCode: id(for:))
        #expect(picked == "en")
    }

    @Test("on a tie the first allowed code wins (deterministic)")
    func tieBreakingPrefersFirstAllowed() {
        // Exact-tie ordering matters: callers may rely on the stable choice.
        let probs: [Float] = [0.25, 0.25, 0, 0, 0, 0, 0]
        let pickedEnFirst = WhisperTranscriber.pickAllowedLanguage(
            probs: probs, allowed: ["en", "pl"], idForCode: id(for:))
        let pickedPlFirst = WhisperTranscriber.pickAllowedLanguage(
            probs: probs, allowed: ["pl", "en"], idForCode: id(for:))
        #expect(pickedEnFirst == "en")
        #expect(pickedPlFirst == "pl")
    }

    @Test("id out of probs bounds is ignored (defensive)")
    func outOfBoundsIdsIgnored() {
        // A short probs array (e.g. older whisper) must not crash on a stub
        // that hands back ids past the end — the helper must skip them.
        let probs: [Float] = [0.4, 0.6, 0.0]  // only 3 entries
        let pickWithBadId: (String) -> Int? = { code in
            if code == "en" { return 0 }
            if code == "huge" { return 999 }
            return nil
        }
        let picked = WhisperTranscriber.pickAllowedLanguage(
            probs: probs, allowed: ["huge", "en"], idForCode: pickWithBadId)
        #expect(picked == "en")
    }
}

/// Round-trip coverage of `WhisperIPCOptions.allowedLanguages` over the JSON
/// wire format the subprocess speaks. The field must be `Codable`, must
/// round-trip identically, and **must default to empty** when an older peer
/// sends a payload without the field — that is what preserves the legacy
/// "unrestricted auto" behaviour during a mixed-version rollout.
@Suite("WhisperIPCOptions.allowedLanguages wire format")
struct WhisperIPCOptionsAllowedLanguagesTests {

    @Test("encoding then decoding round-trips a populated allow list")
    func roundTripsPopulatedAllowList() throws {
        let original = WhisperIPCOptions(
            language: nil,
            allowedLanguages: ["en", "pl"],
            threadCount: 2,
            noSpeechThreshold: 0.6,
            temperature: 0.0,
            temperatureFallbackStep: 0.2,
            vadModelPath: nil)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WhisperIPCOptions.self, from: data)
        #expect(decoded == original)
        #expect(decoded.allowedLanguages == ["en", "pl"])
    }

    @Test("payload from an older peer (no allowed_languages key) decodes to []")
    func decodesLegacyPayloadAsEmpty() throws {
        // A pre-language-allow-list peer would emit this exact shape.
        let json = """
        {
          "thread_count": 1,
          "no_speech_threshold": 0.6,
          "temperature": 0.2,
          "temperature_fallback_step": 0.2
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(WhisperIPCOptions.self, from: json)
        #expect(decoded.allowedLanguages == [])
        #expect(decoded.language == nil)
    }

    @Test("allowedLanguages survives the WhisperOptions ↔ WhisperIPCOptions hop")
    func roundTripsThroughInProcessType() {
        let inProcess = WhisperOptions(
            language: nil,
            allowedLanguages: ["en", "pl", "fr"],
            threadCount: 1,
            noSpeechThreshold: 0.6,
            temperature: 0.2,
            temperatureFallbackStep: 0.2,
            vadModelURL: nil)
        let ipc = WhisperIPCOptions(from: inProcess)
        let back = ipc.toWhisperOptions()
        #expect(back.allowedLanguages == ["en", "pl", "fr"])
    }
}
