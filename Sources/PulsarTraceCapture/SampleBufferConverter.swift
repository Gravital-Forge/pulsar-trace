import AVFoundation
import CoreMedia

/// Bridges capture-API `CMSampleBuffer`s — the buffers AVFoundation and
/// ScreenCaptureKit deliver — to canonical 16 kHz mono Float32 frames.
///
/// The input format is not known until the first buffer arrives, so the
/// underlying `AudioConverter` is built lazily from that buffer's format and
/// rebuilt if a later buffer's format differs (a device change mid-session,
/// R8). Not thread-safe: the owning capture engine feeds it from a single
/// delivery queue.
final class SampleBufferConverter {

    private var converter: AudioConverter?
    private var inputFormat: AVAudioFormat?

    /// Convert one capture-API sample buffer; returns every complete
    /// 320-sample frame it (with carried-over residual) now yields.
    func frames(from sampleBuffer: CMSampleBuffer) -> [[Float]] {
        guard let pcm = Self.pcmBuffer(from: sampleBuffer) else { return [] }
        if inputFormat == nil || inputFormat != pcm.format {
            inputFormat = pcm.format
            converter = try? AudioConverter(inputFormat: pcm.format)
        }
        guard let converter else { return [] }
        return (try? converter.convert(pcm)) ?? []
    }

    /// Drain a final partial frame (zero-padded to 320) at end-of-stream.
    func flush() -> [Float]? {
        converter?.flush()
    }

    /// Copy a `CMSampleBuffer`'s PCM data into an `AVAudioPCMBuffer` carrying
    /// the buffer's own format. Returns `nil` for a non-PCM or empty buffer.
    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer)
        else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: formatDescription)

        let sampleCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard sampleCount > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: sampleCount)
        else { return nil }
        pcm.frameLength = sampleCount

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(sampleCount),
            into: pcm.mutableAudioBufferList)
        guard status == noErr else { return nil }
        return pcm
    }
}
