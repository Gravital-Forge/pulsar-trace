import Foundation

/// Length-prefixed framing for the diarizer-worker socket (D43), mirroring the
/// shape of `IPC/FrameProtocol`: a 4-byte little-endian `UInt32` length, then
/// exactly that many payload bytes. Requests (engine→worker) are binary
/// (requestId + Float32 samples); messages (worker→engine) are JSON-encoded
/// `DiarWorkerMessage`.
public enum DiarWorkerProtocol {

    public enum CodecError: Error, Equatable {
        case shortPrefix
        case shortBody(expected: Int, got: Int)
        case shortRequest
        case oversized(Int)
    }

    /// 1 MiB cap on a single frame body — a request is ~640 KB for a 10 s/16 kHz
    /// window, results are a few KB. Anything larger is a framing error.
    public static let maxBodyBytes = 1 << 20

    // MARK: Encode

    public static func encodeRequest(requestId: UInt64, samples: [Float]) -> Data {
        var body = Data(capacity: 8 + samples.count * 4)
        var id = requestId.littleEndian
        withUnsafeBytes(of: &id) { body.append(contentsOf: $0) }
        for s in samples {
            var bits = s.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { body.append(contentsOf: $0) }
        }
        return prefixed(body)
    }

    public static func encodeMessage(_ message: DiarWorkerMessage) throws -> Data {
        let json = try JSONEncoder().encode(message)
        return prefixed(json)
    }

    private static func prefixed(_ body: Data) -> Data {
        var out = Data(capacity: 4 + body.count)
        var len = UInt32(body.count).littleEndian
        withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
        out.append(body)
        return out
    }

    // MARK: Decode

    /// Split a buffer that begins with a complete length-prefixed frame into
    /// (declaredLength, body). Throws if the prefix or body is short.
    public static func splitLengthPrefixed(_ data: Data) throws -> (length: Int, body: Data) {
        guard data.count >= 4 else { throw CodecError.shortPrefix }
        let len = Int(data.subdata(in: data.startIndex ..< data.startIndex + 4)
            .withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian })
        guard len <= maxBodyBytes else { throw CodecError.oversized(len) }
        let bodyStart = data.startIndex + 4
        guard data.count - 4 >= len else {
            throw CodecError.shortBody(expected: len, got: data.count - 4)
        }
        return (len, data.subdata(in: bodyStart ..< bodyStart + len))
    }

    public static func decodeRequest(_ body: Data) throws -> (requestId: UInt64, samples: [Float]) {
        guard body.count >= 8, (body.count - 8) % 4 == 0 else { throw CodecError.shortRequest }
        let id = body.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).littleEndian }
        let count = (body.count - 8) / 4
        var samples = [Float](repeating: 0, count: count)
        body.withUnsafeBytes { raw in
            let base = raw.baseAddress!.advanced(by: 8)
            for i in 0 ..< count {
                let bits = base.advanced(by: i * 4).loadUnaligned(as: UInt32.self).littleEndian
                samples[i] = Float(bitPattern: bits)
            }
        }
        return (id, samples)
    }

    public static func decodeMessage(_ body: Data) throws -> DiarWorkerMessage {
        try JSONDecoder().decode(DiarWorkerMessage.self, from: body)
    }
}
