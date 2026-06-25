import Foundation

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// An `AudioFrameSource` that reads *unframed* raw `f32le` PCM from a file
/// descriptor and chunks it into canonical 20 ms frames.
///
/// `PipeSource` consumes the length-prefixed `FrameProtocol`; this variant
/// consumes a bare PCM byte stream such as the output of
/// `ffmpeg ... -f f32le -ac 1 -ar 16000 -`. It is the source the engine uses
/// for `pulsartrace-engine --stdin`. A single dedicated reader thread performs
/// the blocking reads and feeds an `AsyncThrowingStream`. A clean EOF is
/// end-of-stream (PT-R75); a trailing partial frame is zero-padded to 20 ms.
public final class RawPCMPipeSource: AudioFrameSource, @unchecked Sendable {
    public typealias Element = AudioStreamEvent

    private let fd: Int32
    private let closeOnFinish: Bool
    private let lock = NSLock()
    private var stopped = false
    private var started = false
    private let stream: AsyncThrowingStream<AudioFrame, Error>
    private let continuation: AsyncThrowingStream<AudioFrame, Error>.Continuation

    public init(fd: Int32, closeOnFinish: Bool = false) {
        self.fd = fd
        self.closeOnFinish = closeOnFinish
        let (s, c) = AsyncThrowingStream<AudioFrame, Error>.makeStream()
        self.stream = s
        self.continuation = c
    }

    public func start() async throws {}

    public func stop() async {
        lock.withLock { stopped = true }
    }

    private var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    public func makeAsyncIterator() -> Iterator {
        startIfNeeded()
        return Iterator(upstream: stream.makeAsyncIterator())
    }

    /// Spawn the single reader thread on first iteration.
    private func startIfNeeded() {
        lock.lock()
        let begin = !started
        started = true
        lock.unlock()
        guard begin else { return }

        let thread = Thread { [self] in
            do {
                try readLoop()
                continuation.finish()
            } catch {
                // A decode failure is a real error — surface it to the consumer
                // via the stream rather than silently emitting empty frames.
                continuation.finish(throwing: error)
            }
            if closeOnFinish { close(fd) }
        }
        thread.stackSize = 1 << 20
        thread.start()
    }

    /// Blocking read loop: accumulate bytes, emit full 20 ms frames. A decode
    /// failure is thrown so the caller can `continuation.finish(throwing:)`
    /// rather than emitting silent empty-sample frames.
    private func readLoop() throws {
        let bytesPerFrame = AudioFormat.bytesPerFrame
        var carry = Data()
        var scratch = [UInt8](repeating: 0, count: 64 * 1024)
        var frameIndex = 0

        func emitFullFrames() throws {
            while carry.count >= bytesPerFrame {
                let frameBytes = Data(carry.prefix(bytesPerFrame))
                carry.removeFirst(bytesPerFrame)
                let samples = try FrameProtocol.decodePayload(frameBytes)
                continuation.yield(AudioFrame(samples: samples, sequenceIndex: frameIndex))
                frameIndex += 1
            }
        }

        while true {
            if isStopped { break }
            let n = scratch.withUnsafeMutableBytes { ptr -> Int in
                read(fd, ptr.baseAddress, ptr.count)
            }
            if n == 0 { break }  // EOF
            if n < 0 {
                if errno == EINTR { continue }
                break
            }
            carry.append(contentsOf: scratch[0..<n])
            try emitFullFrames()
        }

        // Trailing partial frame: zero-pad to a full 20 ms.
        if !carry.isEmpty {
            var bytes = Data(carry)
            let pad = bytesPerFrame - bytes.count
            if pad > 0 { bytes.append(Data(count: pad)) }
            let samples = try FrameProtocol.decodePayload(bytes)
            continuation.yield(AudioFrame(samples: samples, sequenceIndex: frameIndex))
        }
    }

    public struct Iterator: AsyncIteratorProtocol {
        private var upstream: AsyncThrowingStream<AudioFrame, Error>.AsyncIterator

        init(upstream: AsyncThrowingStream<AudioFrame, Error>.AsyncIterator) {
            self.upstream = upstream
        }

        public mutating func next() async throws -> AudioStreamEvent? {
            guard let frame = try await upstream.next() else { return nil }
            return .frame(frame)
        }
    }
}
