import AVFoundation
import PulsarTraceEngine

/// Converts capture-API audio buffers — any sample rate, any channel layout —
/// into the canonical **16 kHz mono Float32** frame format, accumulating the
/// output into fixed 320-sample (20 ms) frames.
///
/// Resampling and downmixing happen here, at the capture-source boundary, so
/// the engine never sees 48 kHz stereo audio: storage is 16 kHz mono (PT-R54e),
/// and the wire format is the 320-sample frame every `AudioFrameSource`
/// produces (Hard Invariant #9).
///
/// One converter instance is stateful — `AVAudioConverter` keeps internal
/// resampler state across calls, and `residual` carries converted samples that
/// did not fill a whole frame — so one instance serves one capture stream for
/// the life of a recording. It is not thread-safe; the owning capture engine
/// feeds it from a single delivery queue.
final class AudioConverter {

    enum ConverterError: Error, CustomStringConvertible {
        case unsupportedFormat
        case conversionFailed(String)

        var description: String {
            switch self {
            case .unsupportedFormat:
                return "could not build an AVAudioConverter for the input format"
            case .conversionFailed(let detail):
                return "audio conversion failed: \(detail)"
            }
        }
    }

    /// The canonical engine-facing format: 16 kHz, mono, non-interleaved F32.
    static let canonicalFormat: AVAudioFormat = {
        // Force-unwrap: these parameters are always valid on macOS.
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(AudioFormat.sampleRate),
            channels: 1,
            interleaved: false)!
    }()

    private let converter: AVAudioConverter
    private let inputFormat: AVAudioFormat
    /// Converted mono samples not yet emitted as a complete 320-sample frame.
    private var residual: [Float] = []

    /// - Parameter inputFormat: the format of the buffers that will be fed in
    ///   (e.g. SCK's 48 kHz stereo, or a mic device's native format).
    init(inputFormat: AVAudioFormat) throws {
        guard let converter = AVAudioConverter(
            from: inputFormat, to: Self.canonicalFormat) else {
            throw ConverterError.unsupportedFormat
        }
        self.converter = converter
        self.inputFormat = inputFormat
    }

    /// Convert one input buffer and return every complete 320-sample frame it
    /// (together with any carried-over residual) now yields. A partial tail is
    /// retained for the next call; `flush()` drains it at end-of-stream.
    func convert(_ input: AVAudioPCMBuffer) throws -> [[Float]] {
        guard input.frameLength > 0 else { return [] }

        // Output capacity: input frames scaled by the rate ratio, plus a small
        // margin for the resampler's filter delay.
        let ratio = Self.canonicalFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(
            (Double(input.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(
            pcmFormat: Self.canonicalFormat, frameCapacity: capacity) else {
            throw ConverterError.conversionFailed("output buffer allocation")
        }

        // Feed the one input buffer exactly once; `.noDataNow` afterwards tells
        // the converter to emit whatever it has without ending its stream, so
        // resampler state carries into the next `convert(_:)` call.
        //
        // `AVAudioConverterInputBlock` is `@Sendable`, but `convert(to:...)`
        // invokes it synchronously on this thread before returning — there is
        // no real concurrency. `InputFeed` is a reference type so the block
        // captures it by `let` and the "mutation in a Sendable closure"
        // diagnostics do not apply; `@unchecked Sendable` records that the
        // single-threaded synchronous use is hand-verified.
        let feed = InputFeed(input)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) {
            _, outStatus in
            guard let buffer = feed.take() else {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            return buffer
        }
        if let conversionError {
            throw ConverterError.conversionFailed(conversionError.localizedDescription)
        }
        if status == .error {
            throw ConverterError.conversionFailed("converter returned .error")
        }

        if let channel = output.floatChannelData, output.frameLength > 0 {
            residual.append(
                contentsOf: UnsafeBufferPointer(
                    start: channel[0], count: Int(output.frameLength)))
        }
        return drainWholeFrames()
    }

    /// Drain a final partial frame, zero-padded to 320 samples, at end-of-stream.
    /// Returns `nil` when nothing is buffered.
    func flush() -> [Float]? {
        guard !residual.isEmpty else { return nil }
        var frame = residual
        residual.removeAll(keepingCapacity: false)
        if frame.count < AudioFormat.samplesPerFrame {
            frame.append(contentsOf: [Float](
                repeating: 0, count: AudioFormat.samplesPerFrame - frame.count))
        }
        return frame
    }

    /// One-shot holder for the input buffer handed to the converter's
    /// `@Sendable` input block. `take()` returns the buffer the first time and
    /// `nil` after — the block then reports `.noDataNow`.
    private final class InputFeed: @unchecked Sendable {
        private var buffer: AVAudioPCMBuffer?
        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
        func take() -> AVAudioPCMBuffer? {
            defer { buffer = nil }
            return buffer
        }
    }

    /// Peel every complete 320-sample frame off the residual buffer.
    private func drainWholeFrames() -> [[Float]] {
        let per = AudioFormat.samplesPerFrame
        var frames: [[Float]] = []
        var offset = 0
        while residual.count - offset >= per {
            frames.append(Array(residual[offset..<offset + per]))
            offset += per
        }
        if offset > 0 { residual.removeFirst(offset) }
        return frames
    }
}
