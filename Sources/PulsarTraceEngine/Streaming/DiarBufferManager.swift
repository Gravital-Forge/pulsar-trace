/// Sliding-window sample buffer for live diarization (Fix B/C extracted
/// from LiveRunner.run()):
///  - emits a `WindowRequest` only when ≥ `stepSamples` of new audio have
///    arrived since the previous emission AND at least one full window is
///    buffered (cadence gating);
///  - trims the buffer to 2× the window so memory stays bounded over an
///    arbitrarily long meeting, tracking the recording-absolute base index
///    so window start positions survive the trim.
///
/// Synchronous and unaware of DiarGate/Tasks: the single-in-flight bound
/// stays at the call site (it awaits an actor).
struct DiarBufferManager {
    struct WindowRequest {
        let samples: [Float]
        /// Recording-absolute index of `samples[0]`.
        let startSampleIndex: Int
    }

    private var buffer: [Float] = []
    private var base = 0          // recording-absolute index of buffer[0]
    private var lastWindowEnd = 0 // absolute index when the last window emitted
    private let stepSamples: Int
    private let windowSamples: Int

    var bufferedSampleCount: Int { buffer.count }

    init(stepSamples: Int, windowSamples: Int) {
        self.stepSamples = stepSamples
        self.windowSamples = windowSamples
    }

    mutating func append(_ samples: [Float]) -> WindowRequest? {
        buffer.append(contentsOf: samples)
        let total = base + buffer.count

        var request: WindowRequest?
        if total - lastWindowEnd >= stepSamples, total >= windowSamples {
            let loAbs = max(0, total - windowSamples)
            let lo = loAbs - base
            lastWindowEnd = total
            if lo >= 0, lo <= buffer.count {
                request = WindowRequest(
                    samples: Array(buffer[lo...]),
                    startSampleIndex: loAbs)
            }
        }

        // Trim on every append, not only on emission (Fix C).
        let keep = 2 * windowSamples
        if buffer.count > keep {
            let trim = buffer.count - keep
            buffer.removeFirst(trim)
            base += trim
        }
        return request
    }
}
