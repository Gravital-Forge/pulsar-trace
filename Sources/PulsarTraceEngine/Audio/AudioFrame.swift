import Foundation

/// The single canonical audio format used everywhere inside the engine.
///
/// PulsarTrace fixes the audio format at the `AudioFrameSource` boundary (R76):
/// 16 kHz, mono, 32-bit float samples, framed at 20 ms. Any conversion or
/// resampling happens inside a source implementation — engine code only ever
/// sees frames in this format.
public enum AudioFormat {
    /// Canonical sample rate in Hz.
    public static let sampleRate: Int = 16_000
    /// Canonical channel count.
    public static let channelCount: Int = 1
    /// Frame duration in milliseconds.
    public static let frameMilliseconds: Int = 20
    /// Samples per frame: 16000 Hz * 0.020 s = 320 samples.
    public static let samplesPerFrame: Int = sampleRate * frameMilliseconds / 1000
    /// Bytes per frame when serialized as little-endian Float32.
    public static let bytesPerFrame: Int = samplesPerFrame * MemoryLayout<Float>.size
}

/// A single 20 ms slice of mono 16 kHz Float32 PCM audio.
///
/// `samples` always holds exactly `AudioFormat.samplesPerFrame` values except
/// for a possible final short frame at end-of-stream. `sequenceIndex` is a
/// monotonically increasing counter assigned by the producing source, used to
/// detect dropped frames and to compute a frame's offset from stream start.
public struct AudioFrame: Sendable, Equatable {
    /// PCM samples in [-1.0, 1.0], little-endian Float32 when serialized.
    public var samples: [Float]
    /// Monotonic frame index assigned by the source, starting at 0.
    public var sequenceIndex: Int

    public init(samples: [Float], sequenceIndex: Int) {
        self.samples = samples
        self.sequenceIndex = sequenceIndex
    }

    /// Offset of this frame from the start of the stream.
    public var startTime: Duration {
        .milliseconds(sequenceIndex * AudioFormat.frameMilliseconds)
    }

    /// A frame of digital silence at the given index.
    public static func silence(sequenceIndex: Int) -> AudioFrame {
        AudioFrame(
            samples: [Float](repeating: 0, count: AudioFormat.samplesPerFrame),
            sequenceIndex: sequenceIndex
        )
    }
}
