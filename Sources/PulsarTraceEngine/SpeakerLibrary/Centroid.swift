import Foundation

/// Centroid vector math for the speaker library (R30, R22).
///
/// A speaker's *centroid* is the running mean of every embedding ever
/// attributed to them. Matching a new recording's cluster to the library is a
/// cosine-similarity lookup; refining a returning speaker is a
/// count-weighted running-mean update. All vectors are WeSpeaker
/// 256-d embeddings and are only comparable within one `model_revision`
/// (Open Question #3 / D40 — `SpeakerLibrary` refuses cross-revision matches).
public enum Centroid {

    /// Cosine similarity of two equal-length vectors, in `[-1, 1]`.
    ///
    /// Returns `0` when the vectors differ in length or either has zero
    /// magnitude — a non-comparable pair is treated as "no similarity" rather
    /// than crashing or producing a spurious match.
    public static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0
        var normA = 0.0
        var normB = 0.0
        for i in 0..<a.count {
            let x = Double(a[i])
            let y = Double(b[i])
            dot += x * y
            normA += x * x
            normB += y * y
        }
        guard normA > 0, normB > 0 else { return 0 }
        return dot / (normA.squareRoot() * normB.squareRoot())
    }

    /// Fold a new appearance embedding into an existing centroid via a
    /// count-weighted running mean (R30):
    ///
    /// ```
    /// new = (old * count + appearance) / (count + 1)
    /// ```
    ///
    /// `count` is the speaker's appearance count *before* this appearance.
    /// A mismatched-length appearance is rejected — the centroid is returned
    /// unchanged — so a stray dimension can never corrupt the stored vector.
    public static func runningMean(
        existing: [Float],
        appearanceCount: Int,
        appearance: [Float]
    ) -> [Float] {
        guard existing.count == appearance.count, appearanceCount >= 0 else {
            return existing
        }
        let n = Double(appearanceCount)
        var result = existing
        for i in 0..<result.count {
            let merged = (Double(existing[i]) * n + Double(appearance[i])) / (n + 1)
            result[i] = Float(merged)
        }
        return result
    }

    /// Mean of a non-empty set of equal-length vectors — used to recompute a
    /// centroid from scratch after a merge re-attributes appearances (R30,
    /// `speaker_merged`). Returns `[]` for an empty input.
    public static func mean(of vectors: [[Float]]) -> [Float] {
        guard let first = vectors.first, !first.isEmpty else { return [] }
        let dim = first.count
        guard vectors.allSatisfy({ $0.count == dim }) else { return first }
        var acc = [Double](repeating: 0, count: dim)
        for v in vectors {
            for i in 0..<dim { acc[i] += Double(v[i]) }
        }
        let n = Double(vectors.count)
        return acc.map { Float($0 / n) }
    }

    /// Reconstruct a primary speaker's *pre-merge* centroid arithmetically,
    /// inverting the count-weighted mean a merge computed (S4).
    ///
    /// A merge computes `merged = (primaryOld·np + other·no) / (np + no)`
    /// where `np` is primary's pre-merge appearance count and `no` is
    /// `other`'s. Solving for `primaryOld`:
    ///
    /// ```
    /// primaryOld = (merged·(np + no) − other·no) / np
    /// ```
    ///
    /// Returns `nil` when the inversion is not exact — `np <= 0` (no
    /// pre-merge appearances to divide by) or a dimension mismatch — so the
    /// caller can fall back rather than store a garbage centroid.
    public static func unmergePrimaryCentroid(
        merged: [Float],
        other: [Float],
        primaryCount: Int,
        otherCount: Int
    ) -> [Float]? {
        guard primaryCount > 0, otherCount >= 0,
              merged.count == other.count, !merged.isEmpty else { return nil }
        let np = Double(primaryCount)
        let no = Double(otherCount)
        let total = np + no
        var result = [Float](repeating: 0, count: merged.count)
        for i in 0..<result.count {
            let value = (Double(merged[i]) * total - Double(other[i]) * no) / np
            result[i] = Float(value)
        }
        return result
    }

    // MARK: - BLOB serialization

    /// Serialize a `Float32` vector as a little-endian byte BLOB for SQLite
    /// storage (R28: "centroid (numpy blob)"). 256 floats → 1024 bytes.
    public static func encodeBlob(_ vector: [Float]) -> Data {
        var data = Data(capacity: vector.count * 4)
        for value in vector {
            var le = value.bitPattern.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// Decode a little-endian `Float32` BLOB back into a vector. Returns `nil`
    /// for a byte count that is not a multiple of 4 (a corrupt row).
    public static func decodeBlob(_ data: Data) -> [Float]? {
        guard data.count % 4 == 0 else { return nil }
        var result = [Float]()
        result.reserveCapacity(data.count / 4)
        var index = data.startIndex
        while index < data.endIndex {
            var bits: UInt32 = 0
            for shift in 0..<4 {
                bits |= UInt32(data[index + shift]) << (8 * shift)
            }
            result.append(Float(bitPattern: bits))
            index += 4
        }
        return result
    }
}
