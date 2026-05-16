import Foundation

/// Single-frequency tone analysis — the frequency-verification half of
/// `pulsartrace doctor --capture-test` (R68).
///
/// Uses the Goertzel algorithm: an O(N) evaluation of one DFT bin, far cheaper
/// than a full FFT when only a handful of candidate frequencies matter. Pure
/// and deterministic, so the detector is unit-testable on synthesized sine
/// samples without any audio hardware.
public enum ToneDetector {

    /// The relative power of `targetHz` in `samples`.
    ///
    /// The value is normalized by sample count, so it is comparable across
    /// recordings of different lengths but is *not* an absolute unit — use it
    /// only to compare frequencies against each other.
    public static func power(
        of samples: [Float], at targetHz: Double, sampleRate: Int
    ) -> Double {
        guard !samples.isEmpty, sampleRate > 0, targetHz > 0 else { return 0 }
        let n = Double(samples.count)
        // Goertzel coefficient for the bin nearest `targetHz`.
        let omega = 2.0 * .pi * targetHz / Double(sampleRate)
        let coeff = 2.0 * cos(omega)

        var sPrev = 0.0
        var sPrev2 = 0.0
        for sample in samples {
            let s = Double(sample) + coeff * sPrev - sPrev2
            sPrev2 = sPrev
            sPrev = s
        }
        let magnitudeSquared =
            sPrev * sPrev + sPrev2 * sPrev2 - coeff * sPrev * sPrev2
        return max(0, magnitudeSquared) / (n * n)
    }

    /// The dominant frequency in `samples`, found by scanning `range` at
    /// `resolution`-Hz steps and taking the highest-power candidate.
    ///
    /// The scan analyzes a centered window of at most `sampleRate / resolution`
    /// samples rather than the whole signal. A long pure tone has a spectral
    /// main lobe far narrower than the grid step, so a full-length scan would
    /// fall *between* grid points and miss the peak; the shortened window
    /// widens the main lobe to span the grid. A centered window also skips the
    /// onset/offset transients of a real capture.
    ///
    /// - Returns: the best-matching frequency in Hz, or `0` for empty input.
    public static func dominantFrequency(
        _ samples: [Float],
        sampleRate: Int,
        range: ClosedRange<Double> = 100...4000,
        resolution: Double = 5
    ) -> Double {
        guard !samples.isEmpty, sampleRate > 0, resolution > 0 else { return 0 }

        let windowLength = min(
            samples.count,
            max(256, Int(Double(sampleRate) / resolution)))
        let start = (samples.count - windowLength) / 2
        let window = Array(samples[start..<start + windowLength])

        var bestFrequency = range.lowerBound
        var bestPower = -1.0
        var frequency = range.lowerBound
        while frequency <= range.upperBound {
            let p = power(of: window, at: frequency, sampleRate: sampleRate)
            if p > bestPower {
                bestPower = p
                bestFrequency = frequency
            }
            frequency += resolution
        }
        return bestFrequency
    }

    /// Whether `samples` carry a tone at `expectedHz` within `toleranceHz`.
    ///
    /// The end-to-end pass/fail for `doctor --capture-test`: a tone is played,
    /// captured back through the real capture path, and its dominant frequency
    /// checked against what was played.
    public static func matches(
        _ samples: [Float],
        expectedHz: Double,
        sampleRate: Int,
        toleranceHz: Double = 25
    ) -> Bool {
        let dominant = dominantFrequency(
            samples, sampleRate: sampleRate,
            range: searchBand(around: expectedHz))
        return abs(dominant - expectedHz) <= toleranceHz
    }

    /// A search band centered on `expectedHz`. The lower bound never drops
    /// below 100 Hz: the Goertzel recurrence is numerically unstable near DC
    /// (its coefficient approaches 2), so low-frequency bins would otherwise
    /// report spurious power and win the scan.
    public static func searchBand(around expectedHz: Double) -> ClosedRange<Double> {
        let low = max(100, expectedHz - 200)
        let high = max(low + 100, expectedHz + 200)
        return low...high
    }

    /// Generate a mono sine tone — the signal `doctor --capture-test` plays.
    public static func sine(
        frequencyHz: Double, sampleRate: Int, duration: Duration, amplitude: Float = 0.6
    ) -> [Float] {
        let seconds = Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
        let count = max(0, Int(seconds * Double(sampleRate)))
        guard count > 0 else { return [] }
        let step = 2.0 * .pi * frequencyHz / Double(sampleRate)
        return (0..<count).map { amplitude * Float(sin(step * Double($0))) }
    }
}
