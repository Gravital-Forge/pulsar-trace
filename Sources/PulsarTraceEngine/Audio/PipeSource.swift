import Foundation

/// An `AudioFrameSource` that reads length-prefixed PCM frames from a file
/// descriptor (R72) — typically stdin.
///
/// This is the source behind `ffmpeg -re ... | pulsartrace-engine --stdin`.
/// Raw `f32le` PCM piped in is read frame-by-frame using `FrameProtocol`
/// framing. (Note: when used with `--stdin` the engine wraps raw PCM stdin in
/// `FrameProtocol` framing via `RawPCMFraming`; see `PipeSource.fromRawPCM`.)
public final class PipeSource: AudioFrameSource {
    public typealias Element = AudioStreamEvent

    private let reader: FrameDescriptorReader

    /// - Parameters:
    ///   - fd: a readable file descriptor carrying `FrameProtocol`-framed PCM.
    ///   - closeOnFinish: close `fd` at end-of-stream. `false` for stdin.
    public init(fd: Int32, closeOnFinish: Bool = false) {
        self.reader = FrameDescriptorReader(fd: fd, closeOnFinish: closeOnFinish)
    }

    public func start() async throws {}

    public func stop() async {
        reader.requestStop()
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(frames: reader.makeFrameIterator())
    }

    public struct Iterator: AsyncIteratorProtocol {
        /// The per-iteration stream iterator. Lives in this value type — never
        /// on the shared reader — so its `mutating next()` is not shared.
        private var frames: AsyncThrowingStream<FrameProtocol.DecodedItem, Error>.AsyncIterator
        private var frameIndex = 0

        init(frames: AsyncThrowingStream<FrameProtocol.DecodedItem, Error>.AsyncIterator) {
            self.frames = frames
        }

        public mutating func next() async throws -> AudioStreamEvent? {
            guard let item = try await frames.next() else { return nil }
            return DecodedItemMapper.event(for: item, frameIndex: &frameIndex)
        }
    }
}
