import Foundation

/// An `AudioFrameSource` that replays a WAV file (R71).
///
/// Two modes:
/// - `realtime: true` — frames are emitted at wall-clock pace (one 20 ms frame
///   every 20 ms). Used to exercise streaming pacing and backpressure.
/// - `realtime: false` — "fast" mode, frames emitted as fast as the consumer
///   can take them. Used by non-streaming pipeline tests where pacing is
///   irrelevant and speed matters.
///
/// The fixture WAV is decoded once at `start()`; tests must commit fixtures to
/// the repo and never regenerate them (determinism rule).
public final class FixturePlaybackSource: AudioFrameSource {
    public typealias Element = AudioStreamEvent

    private let fileURL: URL
    private let realtime: Bool
    private let state = SourceState()

    /// - Parameters:
    ///   - file: a 16 kHz mono PCM WAV (Int16 or Float32).
    ///   - realtime: emit at wall-clock pace (`true`) or as fast as possible (`false`).
    public init(file: URL, realtime: Bool = true) {
        self.fileURL = file
        self.realtime = realtime
    }

    public func start() async throws {
        let wav = try WAVReader(contentsOf: fileURL)
        await state.load(samples: wav.samples)
    }

    public func stop() async {
        await state.requestStop()
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(fileURL: fileURL, realtime: realtime, state: state)
    }

    /// Internal mutable state shared between `start`/`stop` and the iterator.
    actor SourceState {
        private(set) var samples: [Float] = []
        private(set) var loaded = false
        private(set) var stopped = false

        func load(samples: [Float]) {
            self.samples = samples
            self.loaded = true
        }

        func requestStop() { stopped = true }
        var isStopped: Bool { stopped }
    }

    public struct Iterator: AsyncIteratorProtocol {
        private let fileURL: URL
        private let realtime: Bool
        private let state: SourceState
        private var nextSampleIndex = 0
        private var frameIndex = 0
        private var cachedSamples: [Float]?

        init(fileURL: URL, realtime: Bool, state: SourceState) {
            self.fileURL = fileURL
            self.realtime = realtime
            self.state = state
        }

        public mutating func next() async throws -> AudioStreamEvent? {
            // Lazily fetch the decoded samples. If start() was not called the
            // source can still decode here so makeAsyncIterator-only use works.
            if cachedSamples == nil {
                if await state.loaded {
                    cachedSamples = await state.samples
                } else {
                    let wav = try WAVReader(contentsOf: fileURL)
                    cachedSamples = wav.samples
                }
            }
            guard let samples = cachedSamples else { return nil }

            if await state.isStopped { return nil }
            if nextSampleIndex >= samples.count { return nil }

            let per = AudioFormat.samplesPerFrame
            let end = Swift.min(nextSampleIndex + per, samples.count)
            var chunk = Array(samples[nextSampleIndex..<end])
            // Pad a final short frame to a full 20 ms with silence.
            if chunk.count < per {
                chunk.append(contentsOf: [Float](repeating: 0, count: per - chunk.count))
            }
            let frame = AudioFrame(samples: chunk, sequenceIndex: frameIndex)
            nextSampleIndex = end
            frameIndex += 1

            if realtime {
                // `try await` (not `try?`) so a cancelled consuming task
                // propagates `CancellationError` out through the
                // `for try await` loop — structured cancellation must not be
                // swallowed. The explicit `stop()`/`isStopped` path above is
                // complementary: it ends the stream cleanly without throwing.
                try await Task.sleep(for: .milliseconds(AudioFormat.frameMilliseconds))
            }
            return .frame(frame)
        }
    }
}
