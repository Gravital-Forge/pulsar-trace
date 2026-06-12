import Foundation

/// The refine pass's language decision, applied **per region decode**
/// (reproducing the old whisper.cpp per-decode `allowedLanguages`
/// semantics on the WhisperKit backend):
///
/// 1. an explicit language (`refine --language`) pins outright — operator
///    override, not filtered through the allow-list;
/// 2. exactly one allowed code pins;
/// 3. several allowed codes → detect on the region's audio and pin the
///    highest-probability **allowed** code (`WhisperKitRegionTranscriber`
///    runs the actual detection);
/// 4. nothing → full auto-detect.
public enum WhisperKitLanguagePolicy {

    public enum Resolution: Equatable, Sendable {
        case pin(String)
        case detectAmong([String])
        case auto
    }

    public static func resolve(explicit: String?, allowed: [String]) -> Resolution {
        if let explicit, !explicit.isEmpty {
            return .pin(explicit.lowercased())
        }
        let codes = allowed.map { $0.lowercased() }
        switch codes.count {
        case 0: return .auto
        case 1: return .pin(codes[0])
        default: return .detectAmong(codes)
        }
    }
}
